# frozen_string_literal: true

module Realtime
  # 市场数据广播服务
  # 处理所有市场相关的广播，包括ticker、kline、depth等
  class MarketBroadcastService < BaseService
    class << self
      # 广播 Ticker 数据
      def broadcast_ticker(market_id)
        channel = "#{market_id}@TICKER"
        data = fetch_ticker_data(market_id)
        
        return false unless data
        
        broadcast(channel, data)
      end
      
      # 批量广播 Ticker
      def batch_broadcast_tickers(market_ids)
        broadcasts = market_ids.map do |market_id|
          {
            channel: "#{market_id}@TICKER",
            data: fetch_ticker_data(market_id)
          }
        end.compact
        
        batch_broadcast(broadcasts)
      end
      
      # 广播 K线数据
      def broadcast_kline(market_id, interval, kline_data = nil)
        channel = "#{market_id}@KLINE_#{interval}"
        data = kline_data || fetch_kline_data(market_id, interval)

        return false unless data

        # 记录K线广播时间（用于心跳机制判断）
        # 只有非0值K线才记录为真实数据广播
        if data.is_a?(Array) && data[5].to_f > 0  # data[5]是成交量
          Redis.current.setex("kline_last_broadcast:#{channel}", 15, Time.current.to_i)
        end

        broadcast(channel, format_kline_message(channel, data))
      end
      
      # 广播深度数据
      def broadcast_depth(market_id, limit = 20, is_heartbeat = false)
        channel = "#{market_id}@DEPTH_#{limit}"
        data = fetch_depth_data(market_id, limit)
        
        return false unless data
        
        # 添加心跳标记和时间戳
        data[:is_heartbeat] = is_heartbeat if is_heartbeat
        data[:server_time] = Time.current.to_i
        
        # 记录最后更新时间（用于避免心跳和实际更新冲突）
        unless is_heartbeat
          Redis.current.setex("depth_last_update:#{market_id}", 30, Time.current.to_i)
        end
        
        broadcast(channel, format_depth_message(channel, data))
      end
      
      # 广播成交数据
      def broadcast_trade(market_id, trade_data)
        channel = "#{market_id}@TRADE"
        
        broadcast(channel, format_trade_message(channel, trade_data))
      end
      
      # 广播市场概览（实时）
      def broadcast_market_realtime(topic = "MARKET@realtime")
        markets = fetch_active_markets
        data_array = build_market_summary_data(markets)
        
        message = {
          topic: topic,
          data: data_array
        }
        
        broadcast(topic, message)
      end
      
      protected
      
      # 格式化数据（覆盖基类方法）
      def format_data(channel, data, options)
        # 如果数据已经包含正确的格式，直接返回
        return data if data.is_a?(Hash) && data.key?(:topic)
        
        # 否则使用基类的默认格式
        super
      end
      
      private
      
      # 获取 Ticker 数据
      def fetch_ticker_data(market_id)
        redis_key = "market:#{market_id}"
        ticker_data = Redis.current.hgetall(redis_key)
        
        return nil if ticker_data.empty?
        
        format_ticker_array(market_id, ticker_data)
      end
      
      # 获取 K线数据
      def fetch_kline_data(market_id, interval)
        # 使用 MarketData::KlineBuilder
        now = Time.current.to_i
        aligned_time = (now / (interval * 60)) * (interval * 60)
        start_time = aligned_time - (interval * 60)
        
        MarketData::KlineBuilder.build(market_id, interval, start_time, now)
      end
      
      # 获取深度数据
      def fetch_depth_data(market_id, limit)
        # 使用现有的 OrderBookDepth 服务
        service = MarketData::OrderBookDepth.new(market_id, limit)
        service.call
      rescue => e
        Rails.logger.error "[MarketBroadcast] Failed to fetch depth: #{e.message}"
        nil
      end
      
      # 获取活跃市场
      def fetch_active_markets
        Trading::Market
          .select(:market_id, :base_currency)
          .map { |m| { market_id: m.market_id, base_currency: m.base_currency } }
      end
      
      # 构建市场概览数据
      def build_market_summary_data(markets)
        markets.map do |market|
          redis_key = "market:#{market[:market_id]}"
          market_data = Redis.current.hgetall(redis_key)
          
          next if market_data.empty?
          
          format_market_summary(market[:market_id], market_data)
        end.compact
      end
      
      # 格式化方法
      
      def format_ticker_array(market_id, ticker_data)
        [
          market_id.to_i,
          ticker_data["symbol"],
          ticker_data["intvl"].to_i,
          ticker_data["time"],
          ticker_data["open"],
          ticker_data["high"],
          ticker_data["low"],
          ticker_data["close"],
          ticker_data["vol"],
          ticker_data["tor"],
          ticker_data["change"],
          ticker_data["color"]
        ]
      end
      
      def format_kline_message(channel, kline_data)
        {
          topic: channel,
          data: kline_data
        }
      end
      
      def format_depth_message(channel, depth_data)
        {
          topic: channel,
          data: depth_data
        }
      end
      
      def format_trade_message(channel, trade_data)
        {
          topic: channel,
          data: trade_data
        }
      end
      
      def format_market_summary(market_id, data)
        {
          market_id: market_id.to_i,
          last_price: data["close"].to_f,
          volume_24h: data["vol"].to_f,
          change_24h: data["change"],
          high_24h: data["high"].to_f,
          low_24h: data["low"].to_f,
          turnover: data["tor"].to_f
        }
      end
      
    end
  end
end
