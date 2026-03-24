# frozen_string_literal: true

module Sidekiq
  module Election
    # 基于 Redis 单实例的 Leader 选举服务
    # 使用 Fencing Token 保证操作的顺序性和一致性
    class Service
      # Redis Key 定义
      LOCK_KEY = 'sidekiq:leader:lock'.freeze
      TOKEN_KEY = 'sidekiq:leader:token'.freeze

      # 配置读取方法（延迟加载避免Rails初始化问题）
      class << self
        def heartbeat_interval
          @heartbeat_interval ||= config.heartbeat_interval || 10
        end

        def heartbeat_jitter
          @heartbeat_jitter ||= config.heartbeat_jitter || 2
        end

        def ttl_seconds
          @ttl_seconds ||= config.ttl_seconds || 35
        end

        def ttl_ms
          ttl_seconds * 1000
        end

        def max_consecutive_failures
          @max_consecutive_failures ||= config.max_consecutive_failures || 3
        end

        def enabled?
          config.enabled
        end

        def instance
          @instance ||= new(Sidekiq::Cluster::InstanceRegistry.new.instance_id)
        end

        # 启动选举服务
        def start
          return if @running

          instance.start
          @running = true

          # 注册优雅关闭
          at_exit { stop }

          ::Rails.logger.info "[Election] 选举服务已启动"
        end

        # 停止选举服务
        def stop
          return unless @running

          instance.stop
          @running = false
          @instance = nil

          ::Rails.logger.info "[Election] 选举服务已停止"
        end

        # 检查是否为 leader（支持静态和动态两种模式）
        def leader?
          # 静态 Leader 模式：根据 Pod 索引判断（INDEX=0 是 Leader）
          unless enabled?
            instance_index = extract_instance_index
            static_leader = config.static_leader_index || 0
            is_leader = instance_index == static_leader
            ::Rails.logger.debug "[Election] 静态模式: INDEX=#{instance_index}, static_leader=#{static_leader}, is_leader=#{is_leader}"
            return is_leader
          end

          # 动态选举模式：从 Redis 读取锁
          current_lock = Sidekiq.redis { |conn| conn.get(LOCK_KEY) }
          return false if current_lock.nil?

          # 检查锁是否属于当前实例
          # 锁格式: {token}:{instance_id}:{timestamp}
          lock_instance_id = current_lock.split(':')[1]
          lock_instance_id == instance.instance_id
        rescue => e
          ::Rails.logger.error "[Election] 检查leader状态异常: #{e.message}"
          false
        end

        # 从 HOSTNAME 提取 Pod 索引（如 sidekiq-0 -> 0, sidekiq-1 -> 1）
        # 用于静态 Leader 模式判断
        def extract_instance_index
          hostname = ENV['HOSTNAME'] || ''
          match = hostname.match(/(\d+)$/)
          match ? match[1].to_i : 0
        end

        # 获取 fencing token
        def fencing_token
          instance.token
        end

        # Leader 独占操作
        def with_leader
          unless leader?
            ::Rails.logger.info "[Election] 当前实例非 leader，跳过操作"
            return nil
          end

          yield
        rescue => e
          ::Rails.logger.error "[Election] Leader 操作失败: #{e.message}"
          raise
        end

        # 检查是否存在任何 leader（用于 Watchdog）
        def any_leader?
          Sidekiq.redis { |conn| conn.exists(LOCK_KEY) > 0 }
        rescue => e
          ::Rails.logger.error "[Election] 检查 leader 存在异常: #{e.message}"
          false
        end

        # 获取选举状态（从 Redis 读取，支持跨进程查询）
        def status
          current_lock = Sidekiq.redis { |conn| conn.get(LOCK_KEY) }
          current_token = Sidekiq.redis { |conn| conn.get(TOKEN_KEY) }

          if current_lock
            parts = current_lock.split(':')
            lock_token = parts[0]
            lock_instance_id = parts[1]
            lock_timestamp = parts[2].to_i

            {
              instance_id: instance.instance_id,
              is_leader: lock_instance_id == instance.instance_id,
              token: lock_token,
              current_leader: lock_instance_id,
              lock_acquired_at: lock_timestamp > 0 ? Time.at(lock_timestamp / 1000.0) : nil,
              global_token: current_token
            }
          else
            {
              instance_id: instance.instance_id,
              is_leader: false,
              token: nil,
              current_leader: nil,
              lock_acquired_at: nil,
              global_token: current_token
            }
          end
        rescue => e
          ::Rails.logger.error "[Election] 获取状态异常: #{e.message}"
          { instance_id: instance.instance_id, is_leader: false, error: e.message }
        end

        private

        def config
          ::Rails.application.config.x.sidekiq_election
        end
      end

      attr_reader :instance_id, :token, :is_leader, :lock_acquired_at, :last_heartbeat_at

      def initialize(instance_id)
        @instance_id = instance_id
        @token = nil
        @is_leader = false
        @lock_acquired_at = nil
        @heartbeat_thread = nil
        @consecutive_failures = 0
        @lock_value = nil
        @shutting_down = false
        @last_heartbeat_at = nil  # Watchdog 用于检测心跳卡死
      end

    # 启动选举
    def start
      @shutting_down = false
      ::Rails.logger.info "[Election] 开始选举，实例: #{@instance_id}"

      # 生成 token
      @token = generate_fencing_token

      # 尝试获取锁
      if acquire_lock
        @is_leader = true
        @lock_acquired_at = Time.current

        ::Rails.logger.info "[Election] 成功获取 leader，token: #{@token}"

        # 启动心跳线程
        start_heartbeat_thread

        # 记录指标
        record_leader_change

        true
      else
        ::Rails.logger.info "[Election] 获取 leader 失败"
        false
      end
    end

    # 停止选举
    def stop
      @shutting_down = true

      # 标记降级
      @is_leader = false

      # 停止心跳线程
      stop_heartbeat_thread

      # 释放锁
      release_lock

      ::Rails.logger.info "[Election] 实例 #{@instance_id} 已降级"
    end

    # ========== Watchdog 检查用方法 ==========

    # 检查心跳线程是否存活
    def heartbeat_thread_alive?
      @heartbeat_thread&.alive?
    end

    # 检查心跳是否卡死
    def heartbeat_stale?(threshold_seconds)
      return true unless @last_heartbeat_at
      last_heartbeat_age > threshold_seconds
    end

    # 获取距离上次心跳的秒数
    def last_heartbeat_age
      return Float::INFINITY unless @last_heartbeat_at
      (Time.current - @last_heartbeat_at).round(1)
    end

    # 检查锁 TTL 是否处于临界状态
    def lock_ttl_critical?
      return false unless @is_leader
      ttl = current_lock_ttl
      ttl && ttl < (self.class.heartbeat_interval * 2)
    end

    # 获取当前锁的 TTL（秒）
    def current_lock_ttl
      Sidekiq.redis { |conn| conn.pttl(LOCK_KEY) / 1000.0 }
    rescue => e
      ::Rails.logger.error "[Election] 获取锁 TTL 异常: #{e.message}"
      nil
    end

    # ========== Watchdog 恢复用方法 ==========

    # 重启心跳线程
    def restart_heartbeat
      stop_heartbeat_thread

      # 带抖动的重新启动，避免多实例同时重启
      jitter = self.class.heartbeat_jitter
      sleep rand(0.0..jitter.to_f)

      if @is_leader || try_acquire_leader
        start_heartbeat_thread
        true
      else
        false
      end
    end

    # 尝试获取 leader（用于 Watchdog 恢复）
    def try_acquire_leader
      if acquire_lock
        @is_leader = true
        @lock_acquired_at = Time.current
        ::Rails.logger.info "[Election] 重新获取 leader 成功，token: #{@token}"
        start_heartbeat_thread
        true
      else
        false
      end
    rescue => e
      ::Rails.logger.error "[Election] 抢锁异常: #{e.class} - #{e.message}"
      false
    end

    private

    # 生成单调递增的 fencing token
    def generate_fencing_token
      Sidekiq.redis { |conn| conn.incr(TOKEN_KEY) }.to_s
    end

    # 获取锁
    def acquire_lock
      @token ||= generate_fencing_token
      now_ms = (Time.current.to_f * 1000).to_i
      ttl_ms = self.class.ttl_ms

      lua_script = <<-LUA
        local key = KEYS[1]
        local ttl_ms = tonumber(ARGV[1])
        local token = ARGV[2]
        local instance_id = ARGV[3]
        local now_ms = tonumber(ARGV[4])

        local current = redis.call('GET', key)

        -- 锁不存在，获取锁
        if current == false then
          local value = token .. ':' .. instance_id .. ':' .. now_ms
          redis.call('PSETEX', key, ttl_ms, value)
          return {1, value, 'new_lock', now_ms}
        end

        -- 检查锁是否过期（PTTL <= 0 表示已过期或无过期时间）
        local pttl = redis.call('PTTL', key)
        if pttl <= 0 then
          local value = token .. ':' .. instance_id .. ':' .. now_ms
          redis.call('PSETEX', key, ttl_ms, value)
          return {1, value, 'expired_lock', now_ms}
        end

        -- 解析当前值，检查是否是无效格式
        local function parse_value(value)
          local parts = {}
          for part in string.gmatch(value, "([^:]+)") do
            table.insert(parts, part)
          end
          if #parts < 3 then
            return nil
          end
          return {
            token = parts[1],
            instance_id = parts[2],
            timestamp = tonumber(parts[3]) or 0
          }
        end

        local parsed = parse_value(current)
        if not parsed then
          -- 无法解析的值，覆盖它
          local value = token .. ':' .. instance_id .. ':' .. now_ms
          redis.call('PSETEX', key, ttl_ms, value)
          return {1, value, 'invalid_value', now_ms}
        end

        -- 锁被持有，获取失败
        return {0, current, 'lock_held', parsed.timestamp}
      LUA

      Sidekiq.redis do |conn|
        result = conn.call('EVAL', lua_script, 1, LOCK_KEY, ttl_ms, @token, @instance_id, now_ms)

        if result[0] == 1
          @lock_value = result[1]
          ::Rails.logger.info "[Election] 成功获取锁: #{result[2]}, 值: #{@lock_value}"
          return true
        else
          pttl = conn.pttl(LOCK_KEY)
          ::Rails.logger.info "[Election] 锁被占用: #{result[2]}, 时间戳: #{result[3]}, TTL: #{pttl}ms"
          return false
        end
      end
    rescue => e
      ::Rails.logger.error "[Election] 获取锁异常: #{e.message}"
      false
    end

    # 续约锁
    def renew_lock
      return false unless @lock_value

      ttl_ms = self.class.ttl_ms

      lua_script = <<-LUA
        local key = KEYS[1]
        local ttl_ms = tonumber(ARGV[1])
        local expected_value = ARGV[2]

        local current = redis.call('GET', key)

        -- 只有持有者才能续约
        if current == expected_value then
          redis.call('PSETEX', key, ttl_ms, current)
          return {1, 'renewed'}
        else
          return {0, 'not_leader'}
        end
      LUA

      Sidekiq.redis do |conn|
        result = conn.call('EVAL', lua_script, 1, LOCK_KEY, ttl_ms, @lock_value)

        if result[0] == 1
          ::Rails.logger.debug "[Election] 心跳成功，token: #{@token}"
          return true
        else
          ::Rails.logger.error "[Election] 心跳失败: #{result[1]}"
          return false
        end
      end
    rescue => e
      ::Rails.logger.error "[Election] 续约锁异常: #{e.message}"
      false
    end

    # 释放锁
    def release_lock
      return true unless @lock_value

      lua_script = <<-LUA
        local key = KEYS[1]
        local expected_value = ARGV[1]

        local current = redis.call('GET', key)

        -- 只有持有者才能释放
        if current == expected_value then
          redis.call('DEL', key)
          return {1, 'released'}
        else
          return {0, 'not_owner', current or 'nil'}
        end
      LUA

      success = Sidekiq.redis do |conn|
        result = conn.call('EVAL', lua_script, 1, LOCK_KEY, @lock_value)

        if result[0] == 1
          ::Rails.logger.info "[Election] 锁释放成功"
          true
        else
          ::Rails.logger.warn "[Election] 锁释放失败: #{result[1]}, 当前值: #{result[2]}"
          false
        end
      end

      @lock_value = nil
      success
    rescue => e
      ::Rails.logger.error "[Election] 释放锁异常: #{e.message}"
      false
    end

    # 启动心跳线程（加超时保护）
    def start_heartbeat_thread
      @last_heartbeat_at = Time.current  # 初始化
      timeout_seconds = 5  # Redis 操作超时

      @heartbeat_thread = Thread.new do
        Thread.current.name = 'election_heartbeat'
        ::Rails.logger.info "[Election] 心跳线程启动"

        while !@shutting_down && @is_leader
          begin
            Timeout.timeout(timeout_seconds) do  # 超时保护
              if perform_heartbeat
                @last_heartbeat_at = Time.current  # 成功时更新
                @consecutive_failures = 0
                Sidekiq::Election::Monitoring::MetricsCollector.record_heartbeat_success(@instance_id)
              else
                @consecutive_failures += 1
                @last_heartbeat_at = Time.current  # 失败也更新，避免 Watchdog 误判
                ::Rails.logger.warn "[Election] action=renew_failed failures=#{@consecutive_failures}"
                Sidekiq::Election::Monitoring::MetricsCollector.record_heartbeat_failure(@instance_id)
                handle_heartbeat_failure
              end
            end
          rescue Timeout::Error
            @consecutive_failures += 1
            @last_heartbeat_at = Time.current  # 超时也更新 tick
            ::Rails.logger.error "[Election] action=heartbeat_timeout timeout=#{timeout_seconds}s failures=#{@consecutive_failures}"
            Sidekiq::Election::Monitoring::MetricsCollector.record_heartbeat_failure(@instance_id)
            handle_heartbeat_failure
          rescue => e
            @consecutive_failures += 1
            @last_heartbeat_at = Time.current  # 异常也更新 tick
            ::Rails.logger.error "[Election] action=heartbeat_error reason=#{e.class} msg=#{e.message} failures=#{@consecutive_failures}"
            Sidekiq::Election::Monitoring::MetricsCollector.record_heartbeat_failure(@instance_id)
            handle_heartbeat_failure
          end

          # 带抖动的睡眠
          sleep_interval = self.class.heartbeat_interval + rand(0..self.class.heartbeat_jitter)
          sleep sleep_interval
        end

        ::Rails.logger.info "[Election] 心跳线程退出"
      end
    end

    # 执行心跳
    def perform_heartbeat
      if renew_lock
        true
      else
        # 续约失败，立即标记为非 leader
        @is_leader = false
        false
      end
    end

    # 处理心跳失败
    def handle_heartbeat_failure
      if @consecutive_failures >= self.class.max_consecutive_failures
        ::Rails.logger.error "[Election] 心跳连续失败 #{@consecutive_failures} 次，降级为 follower"

        # 立即降级
        @is_leader = false
        stop_heartbeat_thread

        # 发送告警
        send_alert('leader_heartbeat_failure')
      end
    end

    # 停止心跳线程
    def stop_heartbeat_thread
      if @heartbeat_thread
        @heartbeat_thread.kill
        @heartbeat_thread = nil
      end
    end

    # 记录 leader 变更
    def record_leader_change
      # 使用 MetricsCollector 记录指标
      Sidekiq::Election::Monitoring::MetricsCollector.record_leader_change(@instance_id, @token)

      # 记录最后leader时间
      Sidekiq.redis { |conn| conn.set('sidekiq:leader:last_time', Time.current.to_i, ex: 3600) }
    rescue => e
      ::Rails.logger.error "[Election] 记录指标失败: #{e.message}"
    end

    # 发送告警
    def send_alert(type)
      case type
      when 'leader_heartbeat_failure'
        ::Rails.logger.error "[ALERT] Leader 心跳失败: 实例=#{@instance_id}, 连续失败次数=#{@consecutive_failures}, token=#{@token}"
        # 使用监控模块发送告警
        Sidekiq::Election::Monitoring.send_alert(
          'heartbeat_failures',
          {
            instance_id: @instance_id,
            consecutive_failures: @consecutive_failures,
            token: @token
          }
        )
      end
    end
  end
end
end
