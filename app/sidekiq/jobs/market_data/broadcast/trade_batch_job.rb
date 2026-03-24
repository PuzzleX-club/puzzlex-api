# frozen_string_literal: true

module Jobs
  module MarketData
    module Broadcast
      # 批量聚合并广播新增成交
      class TradeBatchJob
        include Sidekiq::Job

        sidekiq_options queue: :default, retry: 2

        def perform(market_id)
          start_time = Time.current
          topic = "#{market_id}@TRADE"

          Rails.logger.info "[MarketData::Broadcast::TradeBatchJob] 开始处理市场 #{market_id} 的 Trade 广播"

          unless has_subscribers?(topic)
            Rails.logger.debug "[MarketData::Broadcast::TradeBatchJob] 市场#{market_id}无订阅者，跳过广播"
            cleanup_pending_trades(market_id)
            return
          end

          pending_ids = get_pending_trade_ids(market_id)
          if pending_ids.empty?
            Rails.logger.debug "[MarketData::Broadcast::TradeBatchJob] 市场#{market_id}无待广播成交"
            return
          end

          fills = Trading::OrderFill.where(id: pending_ids)
                                    .includes(:order)
                                    .order(block_timestamp: :asc)

          new_fills = filter_unbroadcasted_fills(market_id, fills)
          if new_fills.empty?
            Rails.logger.debug "[MarketData::Broadcast::TradeBatchJob] 市场#{market_id}的成交都已广播过"
            cleanup_pending_trades(market_id)
            return
          end

          trades = format_trades(new_fills)
          if trades.empty?
            Rails.logger.warn "[MarketData::Broadcast::TradeBatchJob] 市场#{market_id}的成交数据格式化后为空"
            cleanup_pending_trades(market_id)
            return
          end

          ActionCable.server.broadcast(topic, {
            topic: topic,
            data: trades
          })

          mark_as_broadcasted(market_id, new_fills.map(&:id))
          cleanup_pending_trades(market_id)

          duration = (Time.current - start_time) * 1000
          Rails.logger.info "[MarketData::Broadcast::TradeBatchJob] 完成市场#{market_id}的广播: #{new_fills.size}笔成交, 耗时#{duration.round(2)}ms"
        rescue => e
          Rails.logger.error "[MarketData::Broadcast::TradeBatchJob] 市场#{market_id}广播失败: #{e.message}"
          Rails.logger.error e.backtrace.join("\n")
          raise
        end

        private

        def has_subscribers?(topic)
          ::Realtime::SubscriptionGuard.has_subscribers?(topic)
        end

        def get_pending_trade_ids(market_id)
          redis_key = "pending_trades:#{market_id}"
          ids = Sidekiq.redis { |conn| conn.smembers(redis_key) }
          ids.map(&:to_i).compact
        end

        def filter_unbroadcasted_fills(market_id, fills)
          broadcast_key = "broadcasted_trades:#{market_id}"
          already_broadcasted = Sidekiq.redis { |conn| conn.smembers(broadcast_key) }.map(&:to_i).to_set
          fills.reject { |fill| already_broadcasted.include?(fill.id) }
        end

        def format_trades(fills)
          fills.map do |fill|
            volume = fill.filled_amount.to_f
            next if volume.zero?

            dist = fill.price_distribution&.first
            total_amount = dist ? dist["total_amount"].to_f : 0.0
            price = volume.zero? ? 0.0 : (total_amount / volume)

            direction = fill.order.order_direction
            trade_type = case direction
                         when "Offer" then 1
                         when "List" then 2
                         else 0
                         end

            [
              fill.block_timestamp.to_i,
              price.to_i,
              volume.round(6),
              trade_type
            ]
          end.compact
        end

        def mark_as_broadcasted(market_id, fill_ids)
          return if fill_ids.empty?

          broadcast_key = "broadcasted_trades:#{market_id}"
          Sidekiq.redis do |conn|
            conn.sadd(broadcast_key, fill_ids)
            conn.expire(broadcast_key, 3600)
          end

          Rails.logger.debug "[MarketData::Broadcast::TradeBatchJob] 记录已广播: 市场#{market_id}, #{fill_ids.size}笔成交"
        end

        def cleanup_pending_trades(market_id)
          redis_key = "pending_trades:#{market_id}"
          Sidekiq.redis { |conn| conn.del(redis_key) }
        end
      end
    end
  end
end
