# frozen_string_literal: true

module Orders
  module Events
    # 市场数据更新监听器
    # 监听订单相关事件，更新市场数据和缓存
    class MarketDataUpdater
    # 处理订单履行事件
    def order_fulfilled(event)
      data = event.data
      market_id = data[:market_id]
      
      return unless market_id
      
      Rails.logger.info "[Orders::Events::MarketDataUpdater] Processing order.fulfilled for market #{market_id}"
      
      # 更新市场概览数据
      update_market_summary(market_id, data)
      
      # 触发实时K线更新
      trigger_realtime_kline_update(market_id)
      
      # 更新成交记录缓存
      update_trade_cache(market_id, data)
    end
    
    # 处理订单状态更新事件
    def order_status_updated(event)
      data = event.data
      market_id = data[:market_id]
      
      return unless market_id
      
      Rails.logger.info "[Orders::Events::MarketDataUpdater] Processing order.status_updated for market #{market_id}"
      
      # 如果订单完成或取消，可能需要更新深度数据
      if %w[filled cancelled].include?(data[:new_status])
        trigger_depth_update(market_id)
      end
    end
    
    # 处理订单匹配事件
    def order_matched(event)
      data = event.data
      
      Rails.logger.info "[Orders::Events::MarketDataUpdater] Processing order.matched event #{data[:event_id]}"
      
      # 可以在这里添加匹配相关的数据更新逻辑
      # 比如更新交易对统计、活跃度指标等
    end
    
    private
    
    def update_market_summary(market_id, data)
      # 获取最新的填充记录来更新市场数据
      latest_fill = Trading::OrderFill
                      .where(market_id: market_id)
                      .order(created_at: :desc)
                      .first
      
      return unless latest_fill
      
      # 计算最新价格
      latest_price = MarketData::PriceCalculator.calculate_price_from_fill(latest_fill)
      
      if latest_price > 0
        # 使用Redis服务更新市场数据
        RuntimeCache::MarketDataStore.update_market_field(market_id, "close", latest_price.to_s)
        RuntimeCache::MarketDataStore.update_market_field(market_id, "time", Time.current.to_i.to_s)
        
        # 增加成交量
        RuntimeCache::MarketDataStore.increment_market_field(market_id, "vol", latest_fill.filled_amount.to_f)
        
        Rails.logger.debug "[Orders::Events::MarketDataUpdater] Updated market #{market_id}: price=#{latest_price}, volume=+#{latest_fill.filled_amount}"
      end
    end
    
    def trigger_realtime_kline_update(market_id)
      Jobs::MarketData::Broadcast::Worker.perform_async('kline_batch', {
        batch: [["#{market_id}@KLINE_60", Time.current.to_i]],
        is_realtime: true
      })
    end
    
    def update_trade_cache(market_id, data)
      # 构建成交记录
      trade_record = {
        timestamp: data[:timestamp],
        transaction_hash: data[:transaction_hash],
        market_id: market_id,
        fills_count: data[:fills_count]
      }
      
      # 缓存最新的成交记录
      trades = RuntimeCache::MarketDataStore.get_trades(market_id) || []
      trades << trade_record
      
      # 只保留最近100条记录
      trades = trades.last(100)
      
      RuntimeCache::MarketDataStore.store_trades(market_id, trades)
    end
    
    def trigger_depth_update(market_id)
      Jobs::MarketData::Broadcast::Worker.perform_async('depth', {
        market_id: market_id,
        limit: 20
      })
    end
    end
  end
end
