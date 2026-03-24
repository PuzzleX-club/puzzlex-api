# frozen_string_literal: true

module Jobs
  module Matching
    class PausedRecoveryJob
      include Sidekiq::Job

      sidekiq_options retry: 1, queue: 'scheduler'

      RESCAN_THRESHOLD = 5.minutes
      BATCH_SIZE = 50

      def perform
        # Leader选举检查：只有Leader实例执行暂停订单扫描
        begin
          unless Sidekiq::Election::Service.leader?
            Rails.logger.debug '[Matching::PausedRecovery] 非Leader实例，跳过扫描'
            return
          end
        rescue => e
          # fail-safe: 选举服务异常时记录日志并跳过
          Rails.logger.error "[Matching::PausedRecovery] 选举服务异常: #{e.message}，跳过本次扫描"
          return
        end

        Rails.logger.info '[Matching::PausedRecovery] 开始扫描长时间暂停的订单 (Leader)'

        orders = fetch_paused_orders
        if orders.empty?
          Rails.logger.debug '[Matching::PausedRecovery] 没有需要处理的订单'
          return
        end

        orders.group_by(&:market_id).each do |market_id, market_orders|
          enqueue_recovery(market_id, market_orders)
        end

        Rails.logger.info "[Matching::PausedRecovery] 已处理 #{orders.size} 个暂停订单"
      end

      private

      def fetch_paused_orders
        Trading::Order
          .where(offchain_status: 'paused', offchain_status_reason: 'matching_timeout')
          .where('offchain_status_updated_at <= ?', RESCAN_THRESHOLD.ago)
          .order(:offchain_status_updated_at)
          .limit(BATCH_SIZE)
      end

      def enqueue_recovery(market_id, orders)
        order_hashes = orders.map(&:order_hash)
        Rails.logger.info "[Matching::PausedRecovery] 市场 #{market_id} 重新入队 #{order_hashes.size} 个订单"

        recovery_data = {
          order_hashes: order_hashes,
          failed_at: Time.current.to_f,
          error: 'matching_timeout',
          error_class: 'Timeout::Error',
          market_id: market_id.to_s,
          source: 'paused_recovery',
          reason: 'matching_timeout'
        }

        queue_key = "match_failed_queue:#{market_id}"
        Sidekiq.redis do |conn|
          conn.lpush(queue_key, recovery_data.to_json)
          conn.expire(queue_key, 3600)
        end
      end
    end
  end
end
