# frozen_string_literal: true

module Jobs
  module Indexer
    # 统一链上事件采集器
    # 处理所有链上事件订阅（市场事件 + 实例索引事件）
    # 参考: ADR-062 统一链上日志采集与Handler分发管道
    class EventCollectorJob
      include Sidekiq::Job
      include Throttleable

      # 全局锁配置
      LOCK_KEY = "indexer_event_collector:running"
      LOCK_TTL = 300  # 5分钟，足够处理大批次

      sidekiq_options queue: :indexer_collector, retry: 3, timeout: 60  # 60秒 Job 级别超时

      throttle interval: 2.0  # 2秒内不重复执行

      def perform
        # Leader选举检查：只有Leader实例执行数据收集
        begin
          unless Sidekiq::Election::Service.leader?
            Rails.logger.debug "[EventCollectorJob] 非Leader实例，跳过数据收集"
            return
          end
        rescue => e
          # fail-safe: 选举服务异常时记录日志并跳过
          Rails.logger.error "[EventCollectorJob] 选举服务异常: #{e.message}，跳过本次收集"
          return
        end

        # ⭐ 使用 Throttleable Concern 防止积压任务重复执行
        return if should_throttle?

        # 防重叠：全局 Redis 锁，确保同一时间只有一个 job 运行
        unless acquire_global_lock
          Rails.logger.info "[EventCollectorJob] 上一次任务仍在运行，跳过本次执行"
          return
        end

        Rails.logger.info "[EventCollectorJob] 开始执行数据收集 (Leader)"

        begin
          # 重试上轮跳过的订阅
          retry_skipped_subscriptions

          ::Indexer::EventPipeline::Collector.new.run
          Rails.logger.info "[EventCollectorJob] 数据收集完成"
        rescue Faraday::SSLError => e
          log_rpc_error("SSL连接错误", e)
        rescue Faraday::ConnectionFailed => e
          log_rpc_error("RPC连接失败", e)
        rescue Faraday::TimeoutError => e
          log_rpc_error("RPC请求超时", e)
        rescue => e
          Rails.logger.error "[EventCollectorJob] 数据收集异常: #{e.class} - #{e.message}"
          Rails.logger.error e.backtrace.first(5).join("\n") if e.backtrace
          raise # 重新抛出让Sidekiq重试
        ensure
          release_global_lock
        end
      end

      private

      def acquire_global_lock
        Sidekiq.redis do |conn|
          # SET key value NX EX seconds
          conn.set(LOCK_KEY, hostname, nx: true, ex: LOCK_TTL)
        end
      end

      def release_global_lock
        Sidekiq.redis { |conn| conn.del(LOCK_KEY) }
      end

      def hostname
        @hostname ||= ENV.fetch("HOSTNAME", Socket.gethostname)
      end

      def retry_skipped_subscriptions
        skipped = Sidekiq.redis { |conn| conn.smembers("indexer_event_collector:skipped") }
        return if skipped.empty?

        Rails.logger.info "[EventCollectorJob] 检测到 #{skipped.size} 个上轮跳过的订阅，本轮将重试"
        # 清除跳过记录，本轮重新处理
        Sidekiq.redis { |conn| conn.del("indexer_event_collector:skipped") }
      end

      def log_rpc_error(error_type, exception)
        rpc_endpoint = Rails.application.config.x.indexer&.rpc_endpoint || "未配置"
        Rails.logger.error "[EventCollectorJob] #{error_type}"
        Rails.logger.error "  RPC端点: #{rpc_endpoint}"
        Rails.logger.error "  错误详情: #{exception.message}"
        # RPC错误不重试，等待下一次调度
      end
    end
  end
end
