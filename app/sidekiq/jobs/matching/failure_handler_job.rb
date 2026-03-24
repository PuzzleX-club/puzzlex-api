# frozen_string_literal: true

module Jobs
  module Matching
    class FailureHandlerJob
      include Sidekiq::Job

      sidekiq_options retry: 0, queue: 'scheduler'

      MAX_RETRY_COUNT = 5
      BATCH_SIZE = 20

      def perform
        # Leader选举检查：只有Leader实例执行失败处理
        begin
          unless Sidekiq::Election::Service.leader?
            Rails.logger.debug '[Matching::FailureHandler] 非Leader实例，跳过失败处理'
            return
          end
        rescue => e
          Rails.logger.error "[Matching::FailureHandler] 选举服务异常: #{e.message}，跳过本次处理"
          return
        end

        queue_keys = Sidekiq.redis { |conn| conn.keys('match_failed_queue:*') }
        if queue_keys.empty?
          Rails.logger.debug '[Matching::FailureHandler] 没有失败队列需要处理'
          return
        end

        queue_keys.each do |queue_key|
          process_failed_queue(queue_key)
        end
      end

      private

      def process_failed_queue(queue_key)
        market_id = queue_key.split(':').last
        processed = 0

        while processed < BATCH_SIZE
          message_json = Sidekiq.redis { |conn| conn.rpop(queue_key) }
          break unless message_json

          begin
            message = JSON.parse(message_json)
            handle_failure_message(message, market_id)
          rescue => e
            Rails.logger.error "[Matching::FailureHandler] 处理失败消息异常: #{e.message}"
            Rails.logger.error "[Matching::FailureHandler] 原始消息: #{message_json}"
          end

          processed += 1
        end

        Rails.logger.info "[Matching::FailureHandler] 市场#{market_id}处理失败消息: #{processed}"
      end

      def handle_failure_message(message, market_id)
        order_hashes = message['order_hashes'] || []
        return if order_hashes.empty?

        reason = resolve_reason(message)
        metadata_base = build_metadata(message, market_id)

        order_hashes.each do |order_hash|
          order = Trading::Order.find_by(order_hash: order_hash)
          next unless order
          next if order.offchain_status == 'closed' || order.offchain_status == 'match_failed'

          retry_count = order.offchain_status_metadata.to_h['retry_count'].to_i
          next_retry = retry_count + 1

          reason_for_order = if order.offchain_status_reason.present? && reason == 'matching_failed_soft'
            order.offchain_status_reason
          else
            reason
          end

          metadata = order.offchain_status_metadata.to_h.merge(metadata_base).merge('retry_count' => next_retry)

          if next_retry >= MAX_RETRY_COUNT
            Orders::OrderStatusManager.new(order).set_offchain_status!(
              'match_failed',
              'max_retry_reached',
              metadata
            )
            Rails.logger.info "[Matching::FailureHandler] 订单#{order_hash[0..12]}... 达到上限，标记match_failed(#{next_retry})"
            next
          end

          Orders::OrderStatusManager.new(order).set_offchain_status!(
            'paused',
            reason_for_order,
            metadata
          )

          Rails.logger.info "[Matching::FailureHandler] 订单#{order_hash[0..12]}... 标记paused(#{reason_for_order}, retry=#{next_retry})"
        end
      end

      def resolve_reason(message)
        source = message['source'].to_s
        return message['reason'] if message['reason'].present?

        if message['reason'].to_s == 'matching_timeout' ||
           source == 'match_timeout' ||
           source == 'paused_recovery' ||
           source == 'TimeoutJob' ||
           source.end_with?('::TimeoutJob') ||
           message['error_class'].to_s == 'Timeout::Error'
          return 'matching_timeout'
        end

        return 'matching_failed_hard' if message['is_hard_error']

        'matching_failed_soft'
      end

      def build_metadata(message, market_id)
        {
          'error' => message['error'],
          'error_class' => message['error_class'],
          'failed_at' => message['failed_at'],
          'source' => message['source'] || 'executor',
          'market_id' => market_id,
          'is_hard_error' => message['is_hard_error']
        }.compact
      end
    end
  end
end
