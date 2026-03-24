# frozen_string_literal: true

module Sidekiq
  module Election
    # Watchdog 守护线程
    # 监控心跳线程健康状态，检测异常并自动恢复
    # 职责：仅检测和重启/抢锁，不执行续约
    class Watchdog
    # 指数退避步长（固定值）
    BACKOFF_STEPS = [1, 2, 5, 10, 20, 30].freeze

    class << self
      # 配置读取方法（云原生 - 从环境变量）
      def check_interval
        ::Rails.application.config.x.sidekiq_election.watchdog_check_interval || 20
      end

      def check_jitter
        ::Rails.application.config.x.sidekiq_election.watchdog_check_jitter || 3
      end

      def acquire_jitter
        ::Rails.application.config.x.sidekiq_election.watchdog_acquire_jitter || 5
      end

      def stale_threshold
        ::Rails.application.config.x.sidekiq_election.watchdog_stale_threshold || 30
      end

      def enabled?
        ::Rails.application.config.x.sidekiq_election.watchdog_enabled
      end

      # 启动 Watchdog
      def start
        return unless enabled?
        return if @running  # 单例保证

        @running = true
        @consecutive_failures = 0
        @thread = Thread.new { run_loop }
        @thread.name = 'election_watchdog'
        ::Rails.logger.info "[ElectionWatchdog] 启动"
      end

      # 停止 Watchdog
      def stop
        return unless @running

        @running = false
        @thread&.join(5)  # 等待最多5秒优雅退出
        @thread&.kill if @thread&.alive?
        @thread = nil
        ::Rails.logger.info "[ElectionWatchdog] 已停止"
      end

      def running?
        @running && @thread&.alive?
      end

      private

      def run_loop
        loop do
          break unless @running

          begin
            check_and_recover
            @consecutive_failures = 0
          rescue => e
            @consecutive_failures += 1
            backoff = calculate_backoff(@consecutive_failures)
            ::Rails.logger.error "[ElectionWatchdog] action=error reason=#{e.class} msg=#{e.message} backoff=#{backoff}s"
            sleep backoff
            next  # 跳过本轮正常 sleep
          end

          sleep check_interval + rand(0..check_jitter)
        end
      rescue => e
        # 最外层保护，确保线程不会意外退出
        ::Rails.logger.error "[ElectionWatchdog] action=crash reason=#{e.class} msg=#{e.message}"
        sleep 5
        retry if @running
      end

      def check_and_recover
        service = Service.instance

        # 检查 1: 心跳线程是否存活
        unless service.heartbeat_thread_alive?
          last_tick = service.last_heartbeat_age
          ::Rails.logger.warn "[ElectionWatchdog] action=restart reason=heartbeat_dead last_tick=#{last_tick}s attempts=#{@consecutive_failures + 1}"
          service.restart_heartbeat
          return
        end

        # 检查 2: 心跳是否卡死（最近 tick 时间）
        if service.heartbeat_stale?(stale_threshold)
          last_tick = service.last_heartbeat_age
          ::Rails.logger.warn "[ElectionWatchdog] action=restart reason=heartbeat_stale last_tick=#{last_tick}s attempts=#{@consecutive_failures + 1}"
          service.restart_heartbeat
          return
        end

        # 检查 3: 锁 TTL 预警（仅日志，不主动续约）
        if service.lock_ttl_critical?
          ttl = service.current_lock_ttl
          ::Rails.logger.warn "[ElectionWatchdog] action=warn reason=ttl_critical ttl=#{ttl}s"
          # Watchdog 不执行续约，只告警；心跳线程负责续约
        end

        # 检查 4: 无 leader 状态 - 尝试抢锁
        unless Service.any_leader?
          # 多实例抖动，避免同频抢锁风暴
          sleep rand(0..acquire_jitter)
          ::Rails.logger.warn "[ElectionWatchdog] action=acquire reason=no_leader"
          service.try_acquire_leader
        end
      end

      def calculate_backoff(failures)
        BACKOFF_STEPS[[failures - 1, BACKOFF_STEPS.length - 1].min]
      end
    end
    end
  end
end
