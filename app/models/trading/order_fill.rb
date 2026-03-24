# app/models/trading/order_fill.rb
module Trading
  class OrderFill < ApplicationRecord
    # 广播交易信息
    after_create :enqueue_trade_broadcast
    # 标记市场有变化（用于ticker聚合）
    after_create :mark_market_changed

    belongs_to :order, class_name: 'Trading::Order'
    belongs_to :order_item, class_name: 'Trading::OrderItem'
    belongs_to :market, class_name: 'Trading::Market', optional: true, foreign_key: :market_id, primary_key: :market_id
    has_many :spread_allocations, class_name: 'Trading::SpreadAllocation', dependent: :destroy

    validates :filled_amount, numericality: { greater_than_or_equal_to: 0 }

    # price_distribution可能是数组，每个元素代表一种代币分布:
    # [
    #   {
    #     "token_address": "0xabc123...",
    #     "item_type": 3,
    #     "token_id": "12345",
    #     "recipients": [
    #       { "address": "0xSellerAddress", "amount": "1.0" },
    #       { "address": "0xRoyaltyAddress", "amount": "0.05" }
    #     ]
    #   },
    #   {
    #     "token_address": "0xdef456...",
    #     "item_type": 1,
    #     "token_id": null,
    #     "recipients": [
    #       { "address": "0xPlatformAddress", "amount": "10.0" }
    #     ]
    #   }
    # ]


    private

    def enqueue_trade_broadcast
      # 【新架构：时间窗口聚合 + 增量广播】
      # 1. 将OrderFill ID添加到待广播队列（Redis Set）
      # 2. 尝试获取锁，成功则调度批量广播任务（500ms延迟）
      # 3. 5秒内的后续成交会被聚合到同一任务中处理

      redis_key = "pending_trades:#{self.market_id}"
      lock_key = "trade_broadcast_lock:#{self.market_id}"

      # 添加当前OrderFill ID到待广播集合
      Redis.current.sadd(redis_key, self.id)
      Redis.current.expire(redis_key, 10) # 10秒过期，防止内存泄漏

      # 尝试获取锁（5秒内只调度一次任务）
      acquired = Redis.current.set(lock_key, "1", nx: true, ex: 5)

      if acquired
        # 首次：500ms延迟调度任务（允许短时间内的聚合）
        Jobs::MarketData::Broadcast::TradeBatchJob.perform_in(
          0.5.seconds,
          self.market_id
        )
        Rails.logger.debug "[OrderFill] Trade broadcast scheduled: market #{self.market_id}, OrderFill##{self.id}"
      else
        # 后续：等待已调度的任务处理（聚合）
        Rails.logger.debug "[OrderFill] Trade broadcast already scheduled: market #{self.market_id}, OrderFill##{self.id} awaiting aggregation"
      end
    end

    def mark_market_changed
      # 标记市场有变化，为批量广播（MARKET@1440）维护变化集合
      return unless market_id.present?

      MarketData::FillEventRecorder.record!(self)

      # changed_markets:batch - legacy fallback，待新聚合管线完全上线后删除
      Redis.current.sadd("changed_markets:batch", market_id.to_s)
      Redis.current.expire("changed_markets:batch", 300)

      Rails.logger.debug "[OrderFill] Marked market #{market_id} as changed and recorded fill event"
    end
  end
end
