# frozen_string_literal: true

module Sidekiq
  module Cluster
    # Sidekiq 实例注册与发现服务
    # 用于多实例部署时的实例发现和心跳管理
    class InstanceRegistry
    HEARTBEAT_TTL = 30           # 心跳过期时间（秒）
    HEARTBEAT_INTERVAL = 10      # 心跳间隔（秒）
    MAX_CONSECUTIVE_FAILURES = 3 # 最大连续失败次数
    INSTANCES_KEY = "sidekiq:sharding:instances"

    attr_reader :instance_id

    def initialize
      @instance_id = extract_instance_id
      @consecutive_failures = 0
      @heartbeat_thread = nil
    end

    # 从环境变量或主机名提取实例ID
    # 支持多种命名格式: puzzlex-sidekiq-0, sidekiq-abc123-0, sidekiq-0
    def extract_instance_id
      hostname = ENV['HOSTNAME'] || Socket.gethostname

      case hostname
      when /sidekiq-(\d+)$/
        "sidekiq-#{$1}"
      when /-(\d+)$/
        "sidekiq-#{$1}"
      else
        # 降级：使用进程ID保证唯一性
        safe_log(:warn, "[InstanceRegistry] 无法解析实例编号，使用PID: #{hostname}")
        "sidekiq-pid-#{::Process.pid}"
      end
    end

    # 注册实例到 Redis
    def register
      with_redis do |r|
        r.multi do |txn|
          txn.sadd(INSTANCES_KEY, @instance_id)
          txn.set(heartbeat_key, Time.now.to_i, ex: HEARTBEAT_TTL)
        end
      end
      safe_log(:info, "[InstanceRegistry] 实例 #{@instance_id} 已注册")
    end

    # 发送心跳
    def heartbeat
      with_redis { |r| r.set(heartbeat_key, Time.now.to_i, ex: HEARTBEAT_TTL) }
    end

    # 注销实例
    def deregister
      with_redis do |r|
        r.multi do |txn|
          txn.srem(INSTANCES_KEY, @instance_id)
          txn.del(heartbeat_key)
        end
      end
      safe_log(:info, "[InstanceRegistry] 实例 #{@instance_id} 已注销")
    end

    # 启动心跳线程
    def start_heartbeat_thread
      return if @heartbeat_thread&.alive?

      @heartbeat_thread = Thread.new do
        loop do
          sleep HEARTBEAT_INTERVAL
          begin
            heartbeat
            @consecutive_failures = 0
            safe_log(:debug, "[InstanceRegistry] Heartbeat sent: #{@instance_id}")
          rescue => e
            @consecutive_failures += 1
            if @consecutive_failures >= MAX_CONSECUTIVE_FAILURES
              safe_log(:warn, "[InstanceRegistry] 连续#{@consecutive_failures}次心跳失败: #{e.message}")
            else
              safe_log(:error, "[InstanceRegistry] Heartbeat failed: #{e.message}")
            end
          end
        end
      end
    end

    # 停止心跳线程
    def stop_heartbeat_thread
      @heartbeat_thread&.kill
      @heartbeat_thread = nil
    end

    # 获取所有活跃实例
    # @return [Array<String>] 活跃实例ID列表（已排序）
    def self.get_active_instances
      all = with_redis { |r| r.smembers(INSTANCES_KEY) }
      all.select { |id| with_redis { |r| r.call("EXISTS", "#{INSTANCES_KEY}:#{id}:heartbeat") > 0 } }.sort
    end

    # 检查实例是否活跃
    def self.instance_active?(instance_id)
      with_redis { |r| r.call("EXISTS", "#{INSTANCES_KEY}:#{instance_id}:heartbeat") > 0 }
    end

    # 清理过期实例（从集合中移除）
    def self.cleanup_expired_instances
      all = with_redis { |r| r.smembers(INSTANCES_KEY) }
      expired = all.reject { |id| with_redis { |r| r.call("EXISTS", "#{INSTANCES_KEY}:#{id}:heartbeat") > 0 } }

      expired.each do |id|
        with_redis { |r| r.srem(INSTANCES_KEY, id) }
        new.safe_log(:info, "[InstanceRegistry] 清理过期实例: #{id}")
      end

      expired.size
    end

    def self.with_redis(&block)
      ::Sidekiq.redis(&block)
    end

    # 安全的日志方法，避免 Sidekiq/Rails logger 冲突
    # @param level [Symbol] 日志级别 (:debug, :info, :warn, :error)
    # @param message [String] 日志消息
    def safe_log(level, message)
      if defined?(Rails) && Rails.respond_to?(:logger) && Rails.logger
        Rails.logger.public_send(level, message)
      else
        case level
        when :debug
          # debug 静默忽略
        when :info
          puts message
        when :warn, :error
          warn message
        end
      end
    end

    private

    def with_redis(&block)
      ::Sidekiq.redis(&block)
    end

    def heartbeat_key
      "#{INSTANCES_KEY}:#{@instance_id}:heartbeat"
    end
    end
  end
end
