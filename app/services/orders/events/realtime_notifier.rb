# frozen_string_literal: true

module Orders
  module Events
    # 实时通知监听器
    # 监听订单事件，触发相关的实时广播
    class RealtimeNotifier
      # 处理订单履行事件
      def order_fulfilled(event)
        data = event.data
        market_id = data[:market_id]

        return unless market_id

        Rails.logger.info "[Orders::Events::RealtimeNotifier] Broadcasting updates for order.fulfilled in market #{market_id}"

        # 触发多种广播
        broadcast_ticker_update(market_id)
        broadcast_market_realtime_update
      end

      # 处理订单状态更新事件
      def order_status_updated(event)
        data = event.data
        market_id = data[:market_id]
        new_status = data[:new_status]

        return unless market_id

        Rails.logger.info "[Orders::Events::RealtimeNotifier] Broadcasting status update: #{new_status} for market #{market_id}"

        # 状态变化可能影响订单簿深度
        if %w[filled cancelled partially_filled].include?(new_status)
          broadcast_depth_update(market_id)
        end
      end

      # 处理订单匹配事件
      def order_matched(event)
        data = event.data

        Rails.logger.info "[Orders::Events::RealtimeNotifier] Broadcasting order match notification"

        # 订单匹配是重要事件，触发全局更新
        broadcast_market_realtime_update

        # 如果能从 matched_orders 中提取市场信息，也可以触发特定市场更新
        # 这里简化处理
      end

      private

      def broadcast_ticker_update(market_id)
        Jobs::MarketData::Generation::MarketAggregateJob.perform_async([market_id])
        Jobs::MarketData::Broadcast::MarketSnapshotJob.perform_in(5.seconds)
      end

      def broadcast_depth_update(market_id)
        Jobs::MarketData::Broadcast::Worker.perform_async('depth', {
          market_id: market_id,
          limit: 20
        })
      end

      def broadcast_market_realtime_update
        Jobs::MarketData::Broadcast::Worker.perform_async('market_realtime', {
          topic: 'MARKET@realtime'
        })
      end
    end
  end
end
