# frozen_string_literal: true

module Sidekiq
  module Election
    # 选举服务的监控和告警系统
    class Monitoring
    # 监控检查间隔（秒）
    CHECK_INTERVAL = 30

    # 告警阈值
    ALERT_THRESHOLDS = {
      no_leader_duration: 60,       # 无leader超过60秒
      frequent_elections: 3,        # 5分钟内选举超过3次
      heartbeat_failures: 3         # 心跳连续失败3次
    }.freeze

    def self.start_monitoring
      ::Rails.logger.info "[ElectionMonitoring] 启动选举监控"

      Thread.new do
        loop do
          begin
            check_all_conditions
            sleep CHECK_INTERVAL
          rescue => e
            ::Rails.logger.error "[ElectionMonitoring] 监控异常: #{e.message}"
          end
        end
      end
    end

    private

    # 检查所有告警条件
    def self.check_all_conditions
      check_no_leader
      check_election_frequency
      check_heartbeat_health
    end

    # 检查无leader状态
    def self.check_no_leader
      status = Service.status

      unless status[:is_leader]
        # 检查Redis中是否有锁
        lock_value = Sidekiq.redis { |conn| conn.get(Service::LOCK_KEY) }

        if lock_value.nil?
          # 无锁状态，计算持续时间
          last_leader_time = get_last_leader_time
          duration = Time.current - last_leader_time

          if duration > ALERT_THRESHOLDS[:no_leader_duration]
            send_alert(
              'no_leader',
              {
                duration: duration.round(2),
                last_leader: last_leader_time.strftime('%Y-%m-%d %H:%M:%S')
              }
            )
          end
        end
      end
    rescue => e
      ::Rails.logger.error "[ElectionMonitoring] 检查无leader状态失败: #{e.message}"
    end

    # 检查选举频率
    def self.check_election_frequency
      window = 300  # 5分钟窗口
      threshold = ALERT_THRESHOLDS[:frequent_elections]

      recent_changes = count_recent_leader_changes(window)

      if recent_changes >= threshold
        send_alert(
          'frequent_elections',
          {
            count: recent_changes,
            window: "#{window / 60}分钟"
          }
        )
      end
    rescue => e
      ::Rails.logger.error "[ElectionMonitoring] 检查选举频率失败: #{e.message}"
    end

    # 检查心跳健康
    def self.check_heartbeat_health
      # 这里可以添加心跳失败的监控逻辑
      # 由于心跳失败已经在ElectionService中处理，这里主要做额外检查

      # 获取最近5分钟的失败次数
      recent_failures = get_recent_heartbeat_failures(300)

      if recent_failures >= ALERT_THRESHOLDS[:heartbeat_failures]
        send_alert(
          'heartbeat_failures',
          {
            count: recent_failures,
            window: '5分钟'
          }
        )
      end
    rescue => e
      ::Rails.logger.error "[ElectionMonitoring] 检查心跳健康失败: #{e.message}"
    end

    # 获取最后leader时间
    def self.get_last_leader_time
      # 尝试从Redis获取最后leader时间
      last_time = Sidekiq.redis { |conn| conn.get('sidekiq:leader:last_time') }

      if last_time
        Time.at(last_time.to_i)
      else
        # 默认返回当前时间减去2分钟
        Time.current - 120
      end
    end

    # 统计最近的leader变更次数
    def self.count_recent_leader_changes(window_seconds)
      # 这是一个简化的实现，实际应该从指标系统获取
      # 这里可以集成到Prometheus或时序数据库

      current_time = Time.current.to_i
      window_start = current_time - window_seconds

      # 从Redis获取最近的变更记录（如果有的话）
      recent_changes = Sidekiq.redis do |conn|
        conn.zrange(
          'sidekiq:leader:changes',
          window_start,
          current_time,
          byscore: true
        )
      end

      recent_changes.size
    end

    # 获取最近的心跳失败次数
    def self.get_recent_heartbeat_failures(window_seconds)
      # 简化实现，实际应该从指标系统获取
      0  # 暂时返回0，避免误报
    end

    # 发送告警
    def self.send_alert(alert_type, metadata = {})
      alert_data = {
        timestamp: Time.current.iso8601,
        type: alert_type,
        severity: alert_severity(alert_type),
        metadata: metadata,
        service: 'sidekiq-election'
      }

      # 记录日志
      log_message = build_alert_log_message(alert_data)
      ::Rails.logger.error "[ALERT] #{log_message}"

      # 可以集成到其他告警系统
      # DingTalkService.notify(alert_data)
      # SlackService.notify(alert_data)
      # PagerDutyService.trigger(alert_data)
    end

    # 获取告警严重级别
    def self.alert_severity(alert_type)
      case alert_type
      when 'no_leader'
        'critical'
      when 'frequent_elections', 'heartbeat_failures'
        'warning'
      else
        'info'
      end
    end

    # 构建告警日志消息
    def self.build_alert_log_message(alert_data)
      case alert_data[:type]
      when 'no_leader'
        "系统无leader已超过#{alert_data[:metadata][:duration]}秒！最后leader时间: #{alert_data[:metadata][:last_leader]}"
      when 'frequent_elections'
        "选举过于频繁：#{alert_data[:metadata][:window]}内发生了#{alert_data[:metadata][:count]}次选举"
      when 'heartbeat_failures'
        "心跳失败过多：#{alert_data[:metadata][:window]}内失败了#{alert_data[:metadata][:count]}次"
      else
        "未知告警类型: #{alert_data[:type]}"
      end
    end

    # 指标收集器
    # Prometheus是可选的，当gem不可用时优雅降级
    class MetricsCollector
      @prometheus_available = defined?(Prometheus::Client)

      def self.prometheus_available?
        @prometheus_available = !!defined?(Prometheus::Client) if @prometheus_available.nil?
        @prometheus_available
      end

      def self.initialize_metrics
        return unless prometheus_available?

        begin
          prometheus = Prometheus::Client.registry

          # 定义所有指标
          @leader_changes_total = prometheus.counter(
            :sidekiq_leader_changes_total,
            docstring: 'Total number of leader changes',
            labels: [:instance_id]
          )

          @leader_heartbeat_success_total = prometheus.counter(
            :sidekiq_leader_heartbeat_success_total,
            docstring: 'Total successful heartbeats',
            labels: [:instance_id]
          )

          @leader_heartbeat_failure_total = prometheus.counter(
            :sidekiq_leader_heartbeat_failure_total,
            docstring: 'Total failed heartbeats',
            labels: [:instance_id]
          )

          @leader_token = prometheus.gauge(
            :sidekiq_leader_token,
            docstring: 'Current leader fencing token',
            labels: [:instance_id]
          )

          @no_leader_duration_seconds = prometheus.gauge(
            :sidekiq_no_leader_duration_seconds,
            docstring: 'Duration without a leader (seconds)'
          )

          @leader_elections_total = prometheus.counter(
            :sidekiq_leader_elections_total,
            docstring: 'Total election attempts',
            labels: [:instance_id, :result]
          )

          ::Rails.logger.info "[MetricsCollector] Prometheus指标已初始化"
        rescue => e
          @leader_changes_total = nil
          @leader_heartbeat_success_total = nil
          @leader_heartbeat_failure_total = nil
          @leader_token = nil
          @no_leader_duration_seconds = nil
          @leader_elections_total = nil
          ::Rails.logger.warn "[MetricsCollector] Prometheus初始化失败，降级为仅Redis记录: #{e.message}"
          @prometheus_available = false
        end
      end

      def self.record_leader_change(instance_id, token)
        @leader_changes_total&.increment(labels: { instance_id: instance_id }) if @prometheus_available
        @leader_token&.set(token.to_i, labels: { instance_id: instance_id }) if @prometheus_available

        # 记录到Redis用于告警检查（始终执行）
        Sidekiq.redis do |conn|
          conn.zadd('sidekiq:leader:changes', Time.current.to_i, "#{instance_id}:#{token}")
          conn.expire('sidekiq:leader:changes', 3600)  # 1小时过期
        end
      rescue => e
        ::Rails.logger.error "[MetricsCollector] 记录leader变更失败: #{e.message}"
      end

      def self.record_heartbeat_success(instance_id)
        return unless @prometheus_available
        @leader_heartbeat_success_total&.increment(labels: { instance_id: instance_id })
      rescue => e
        ::Rails.logger.debug "[MetricsCollector] 记录心跳成功失败: #{e.message}"
      end

      def self.record_heartbeat_failure(instance_id)
        return unless @prometheus_available
        @leader_heartbeat_failure_total&.increment(labels: { instance_id: instance_id })
      rescue => e
        ::Rails.logger.debug "[MetricsCollector] 记录心跳失败失败: #{e.message}"
      end

      def self.record_election_attempt(instance_id, result)
        return unless @prometheus_available
        @leader_elections_total&.increment(labels: { instance_id: instance_id, result: result })
      rescue => e
        ::Rails.logger.debug "[MetricsCollector] 记录选举尝试失败: #{e.message}"
      end

      def self.update_no_leader_duration(seconds)
        return unless @prometheus_available
        @no_leader_duration_seconds&.set(seconds)
      rescue => e
        ::Rails.logger.debug "[MetricsCollector] 更新无leader时长失败: #{e.message}"
      end
    end
    end
  end
end
