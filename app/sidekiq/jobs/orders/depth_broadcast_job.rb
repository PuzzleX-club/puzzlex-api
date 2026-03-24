# app/jobs/depth_broadcast_job.rb
module Jobs::Orders
  class DepthBroadcastJob
    include Sidekiq::Job

    sidekiq_options queue: :default, retry: false

    def perform(market_id)
      return if market_id.blank?

      Rails.logger.info "[DepthBroadcastJob] 开始处理市场 #{market_id} 的订单簿广播"

      # 1) 获取订阅的深度档位；异常时回退默认档位
      distinct_limits = ::Realtime::SubscriptionGuard.depth_limits_for_market(market_id)
      return if distinct_limits.empty?

      Rails.logger.debug "[DepthBroadcastJob] 市场 #{market_id} 需要广播的深度: #{distinct_limits.join(', ')}"

      # 2) 取最大深度, 做一次数据库/订单簿聚合 (启用criteria验证)
      max_limit = distinct_limits.max
      max_depth_info = MarketData::OrderBookDepth.new(market_id, max_limit, validate_criteria: true).call
      # => { bids: [...], asks: [...], market_id:..., levels: max_limit }

      Rails.logger.info "[DepthBroadcastJob] 市场 #{market_id} 获取到有效订单 - 买单: #{max_depth_info[:bids]&.size || 0}, 卖单: #{max_depth_info[:asks]&.size || 0}"

      # 3) 针对 distinct_limits，每种深度做 "多次广播"
      distinct_limits.each do |limit|
        # 对 bids/asks 做截取
        # todo：需要验证截取的顺序是否正确
        depth_data = {
          market_id: market_id,
          symbol: market_id,
          levels: limit,
          bids: max_depth_info[:bids].first(limit),
          asks: max_depth_info[:asks].first(limit),
          ts: Time.now.to_i
        }
        # 4) 逐个广播 "market_id@DEPTH_{limit}"
        topic = "#{market_id}@DEPTH_#{limit}"
        ActionCable.server.broadcast(topic, {
          topic: topic,
          data: depth_data
        })
      end
    end
  end
end
