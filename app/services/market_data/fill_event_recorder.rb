# frozen_string_literal: true

module MarketData
  # 负责将 OrderFill 写入事件队列表，供增量聚合流水线消费
  class FillEventRecorder
    class << self
      def record!(order_fill)
        return unless order_fill&.market_id

        Trading::MarketFillEvent.insert!(order_fill)
      rescue => e
        Rails.logger.error("[FillEventRecorder] Failed to record fill##{order_fill&.id}: #{e.message}")
        Sentry.capture_exception(e) if defined?(Sentry)
      end
    end
  end
end
