# frozen_string_literal: true

require 'bigdecimal'

module MarketData
  # Ticker计算服务
  # 统一管理ticker数据的计算逻辑，支持多周期计算和时间对齐
  class TickerCalculator
    # 支持的周期（分钟 => 秒）
    INTERVALS = {
      30 => 1800,     # 30分钟
      60 => 3600,     # 1小时
      360 => 21600,   # 6小时
      720 => 43200,   # 12小时
      1440 => 86400,  # 1天
      10080 => 604800 # 7天
    }.freeze

    class << self
      # 计算特定周期的ticker
      # @param market_id [Integer|String] 市场ID
      # @param interval_minutes [Integer] 周期（分钟）
      # @return [Hash] ticker数据
      def calculate_with_interval(market_id, interval_minutes)
        interval_seconds = INTERVALS[interval_minutes]
        unless interval_seconds
          Rails.logger.error "[TickerCalculator] 不支持的周期: #{interval_minutes}分钟"
          return nil
        end

        current_time = Time.current.to_i

        # 计算当前K线的时间边界（对齐）
        kline_time = align_time(current_time, interval_seconds)
        kline_start = kline_time
        kline_end = kline_time + interval_seconds

        Rails.logger.debug "[TickerCalculator] 计算ticker - 市场: #{market_id}, 周期: #{interval_minutes}分钟, K线时间: #{kline_start}-#{kline_end}"

        # 获取该时间范围内的成交数据（不超过当前时间）
        # Ticker是当前K线周期的实时预览，查询从周期开始到当前时间的OrderFill
        query_end_time = [current_time, kline_end].min
        fills = Trading::OrderFill
          .where(market_id: market_id)
          .where("block_timestamp >= ? AND block_timestamp <= ?", kline_start, query_end_time)
          .order(:block_timestamp)

        ticker_data = if fills.any?
          calculate_ohlc_from_fills(fills, market_id, kline_time, interval_minutes, interval_seconds)
        else
          # 无成交，从上一个周期或历史数据获取
          get_ticker_from_previous(market_id, kline_time, interval_minutes, interval_seconds)
        end

        # 存储到特定interval的Redis key
        if ticker_data
          store_ticker_to_redis(market_id, interval_seconds, ticker_data)
        end

        ticker_data
      end

      # 批量计算多个市场的特定周期ticker
      # @param market_ids [Array] 市场ID数组
      # @param interval_minutes [Integer] 周期（分钟）
      # @return [Array<Hash>] ticker数组
      def batch_calculate_with_interval(market_ids, interval_minutes)
        return [] if market_ids.empty?

        market_ids.map do |market_id|
          calculate_with_interval(market_id, interval_minutes)
        end.compact
      end

      # 计算单个市场的实时ticker（兼容旧接口）
      # @deprecated 请使用 calculate_with_interval
      # @param market_id [Integer|String] 市场ID
      # @return [Hash] ticker数据
      def calculate(market_id)
        Rails.logger.warn "[TickerCalculator] 使用已废弃的calculate方法，请使用calculate_with_interval"
        calculate_with_interval(market_id, 1440) # 默认24小时
      end

      # 批量计算实时ticker
      # @param market_ids [Array<Integer|String>] 市场ID数组
      # @return [Array<Hash>] ticker数组
      def batch_calculate(market_ids)
        return [] if market_ids.empty?

        # 使用Pipeline批量读取Redis数据
        results = Redis.current.pipelined do |pipeline|
          market_ids.each do |market_id|
            pipeline.hgetall("market:#{market_id}")
          end
        end

        # 处理结果
        market_ids.zip(results).map do |market_id, data|
          if data.empty? || missing_ohlc?(data)
            # 对缺失数据的市场进行初始化
            initialize_ohlc(market_id)
            data = Redis.current.hgetall("market:#{market_id}")
          end
          format_ticker(market_id, data)
        end.compact
      end

      # 批量计算24小时ticker
      # @param market_ids [Array<Integer|String>] 市场ID数组
      # @return [Array<Hash>] 24小时ticker数组
      def batch_calculate_24h(market_ids)
        return [] if market_ids.empty?

        markets = Trading::Market.where(market_id: market_ids).index_by(&:market_id)
        stats = Trading::MarketIntradayStat.where(market_id: market_ids).index_by(&:market_id)

        market_ids.map do |market_id|
          market = markets[market_id.to_s]
          next unless market

          stat = stats[market_id]
          if stat
            format_stat_ticker(market, stat)
          else
            data = Redis.current.hgetall("market:#{market_id}")
            format_24h_ticker(market, data)
          end
        end.compact
      end

      private

      # 时间对齐（向下取整到interval边界）
      def align_time(timestamp, interval_seconds)
        timestamp - (timestamp % interval_seconds)
      end

      # 从成交记录计算OHLC
      def calculate_ohlc_from_fills(fills, market_id, kline_time, interval_minutes, interval_seconds)
        prices = fills.map { |fill| calculate_price_from_fill(fill) }.compact

        return nil if prices.empty?

        open_price = prices.first
        high_price = prices.max
        low_price = prices.min
        close_price = prices.last

        # 计算成交量和成交额
        volume = fills.sum(&:filled_amount).to_f
        turnover = fills.sum do |fill|
          price = calculate_price_from_fill(fill)
          price ? price * fill.filled_amount : 0
        end

        # 注意：price已经是Wei格式（从OrderFill计算得到）
        # 保持Wei整数格式，不做除法转换
        {
          market_id: market_id.to_s,
          interval: interval_minutes,           # 分钟数
          interval_seconds: interval_seconds,   # 秒数
          kline_time: kline_time,              # K线开始时间（对齐的）
          time: Time.current.to_i,             # ticker生成时间
          open: open_price.round(0).to_i,      # Wei整数
          high: high_price.round(0).to_i,
          low: low_price.round(0).to_i,
          close: close_price.round(0).to_i,
          volume: volume.round(2),
          turnover: turnover.round(0).to_i,    # Wei整数
          change: calculate_change(close_price, open_price),
          color: get_color(close_price, open_price)
        }
      end

      # 无成交时从前一个周期获取数据
      def get_ticker_from_previous(market_id, kline_time, interval_minutes, interval_seconds)
        # 尝试从Redis获取上一个ticker
        redis_key = "ticker:#{market_id}:#{interval_seconds}"
        prev_data = Redis.current.hgetall(redis_key)

        cache_price = prev_data["close"]&.to_f || 0

        valid_cache = cache_price > 1  # 允许实际价格为Wei，1认为是占位

        close_price = if valid_cache
          cache_price
        else
          # 从数据库获取最近的成交价格
          last_fill = Trading::OrderFill
            .where(market_id: market_id)
            .where("block_timestamp < ?", kline_time)
            .order(block_timestamp: :desc)
            .first

          calculated = last_fill ? calculate_price_from_fill(last_fill) : 0
          calculated = calculated.to_f if calculated

          if calculated.nil? || calculated <= 1
            # 没有有效历史数据
            0
          else
            calculated
          end
        end

        return nil if close_price.nil? || close_price <= 1

        {
          market_id: market_id.to_s,
          interval: interval_minutes,
          interval_seconds: interval_seconds,
          kline_time: kline_time,
          time: Time.current.to_i,
          open: close_price,
          high: close_price,
          low: close_price,
          close: close_price,
          volume: 0,
          turnover: 0,
          change: "0",
          color: "#FFFFF0"
        }
      end

      # 存储ticker到Redis
      def store_ticker_to_redis(market_id, interval_seconds, ticker_data)
        redis_key = "ticker:#{market_id}:#{interval_seconds}"

        # 格式化数据，ticker_data中的价格已经是Wei整数格式
        # 不需要再乘以10^18，直接转为字符串存储
        formatted_data = ticker_data.each_with_object({}) do |(key, value), memo|
          key_str = key.to_s
          memo[key_str] = case value
                          when BigDecimal
                            if key_str == 'volume'
                              value.to_s('F')
                            else
                              value.to_i.to_s
                            end
                          when Integer
                            value.to_s
                          when Float
                            if key_str == 'volume'
                              BigDecimal(value.to_s).to_s('F')
                            else
                              BigDecimal(value.to_s).to_i.to_s
                            end
                          else
                            value.to_s
                          end
        end

        # 将ticker数据存储为hash
        Redis.current.mapped_hmset(redis_key, formatted_data)

        # 设置过期时间（2倍interval时长）
        Redis.current.expire(redis_key, interval_seconds * 2)

        Rails.logger.debug "[TickerCalculator] 存储ticker到Redis: #{redis_key}, 价格格式: Wei整数"
      end

      # 计算价格变化百分比
      def calculate_change(close_price, open_price)
        return "0" if open_price.zero?

        change = ((close_price - open_price) / open_price * 100).round(2)
        change.to_s
      end

      # 获取颜色
      def get_color(close_price, open_price)
        if close_price > open_price
          "#0ECB81"  # 涨-绿色
        elsif close_price < open_price
          "#F6465D"  # 跌-红色
        else
          "#FFFFF0"  # 平-白色
        end
      end

      # 检查OHLC数据是否缺失（保留用于兼容）
      def missing_ohlc?(data)
        %w[open high low close].any? { |field| data[field].nil? || data[field].to_f == 0 }
      end

      # 初始化OHLC数据
      # @param market_id [Integer|String] 市场ID
      def initialize_ohlc(market_id)
        # 获取最近24小时的成交记录
        fills = Trading::OrderFill
          .where(market_id: market_id)
          .where(created_at: 24.hours.ago..Time.current)
          .order(:created_at)

        if fills.any?
        prices = fills.map { |fill| MarketData::PriceCalculator.calculate_price_from_fill(fill) }
                       .reject(&:zero?)

        if prices.any?
          # 计算OHLC
          open_price = BigDecimal(prices.first.to_s)
          high_price = prices.map { |p| BigDecimal(p.to_s) }.max
          low_price = prices.map { |p| BigDecimal(p.to_s) }.min
          close_price = BigDecimal(prices.last.to_s)

          # 计算成交量和成交额
          volume = fills.reduce(BigDecimal('0')) do |sum, fill|
            sum + BigDecimal(fill.filled_amount.to_s)
          end
          turnover = fills.reduce(BigDecimal('0')) do |sum, fill|
            price = MarketData::PriceCalculator.calculate_price_from_fill(fill)
            sum + (BigDecimal(price.to_s) * BigDecimal(fill.filled_amount.to_s))
          end

            # 存储到Redis
            # 注意：price已经是Wei格式，不要再乘10^18
            Redis.current.hmset(
              "market:#{market_id}",
              "market_id", market_id,
            "open", open_price.to_i.to_s,
            "high", high_price.to_i.to_s,
            "low", low_price.to_i.to_s,
            "close", close_price.to_i.to_s,
            "close_val", close_price.to_i.to_s,
            "vol", volume.to_s,
            "tor", turnover.to_i.to_s,
            "time", Time.current.to_i
          )

          # 计算涨跌幅
          update_change_ratio(market_id, close_price, open_price)
          else
            # 没有有效价格，设置默认值
            set_default_ticker(market_id)
          end
        else
          # 没有成交记录，设置默认值
          set_default_ticker(market_id)
        end
      end

      # 从OrderFill计算价格
      def calculate_price_from_fill(fill)
        return nil unless fill.price_distribution.is_a?(Array) && fill.price_distribution.size == 1

        dist = fill.price_distribution.first
        total_amount = dist["total_amount"].to_f
        volume = fill.filled_amount.to_f

        return nil if volume.zero?

        total_amount / volume
      end

      # 设置默认ticker值
      def set_default_ticker(market_id)
        # 默认价格：1 ETH = 10^18 Wei
        # 清理旧缓存，避免前端看到占位价格
        Redis.current.del("ticker:#{market_id}:#{INTERVALS[1440]}")
        nil
      end

      # 更新涨跌幅
      def update_change_ratio(market_id, current_price, reference_price)
        current = BigDecimal(current_price.to_s)
        reference = BigDecimal(reference_price.to_s)

        ratio = reference.zero? ? BigDecimal('0') : ((current - reference) / reference)
        change_str = (ratio * 100).round(2).to_s

        color = "#FFFFF0"
        color = "#0ECB81" if current > reference
        color = "#F6465D" if current < reference

        Redis.current.hmset(
          "market:#{market_id}",
          "change", change_str,
          "color", color
        )
      end

      # 格式化实时ticker
      def format_ticker(market_id, data)
        return nil if data.empty?

        {
          market_id: market_id.to_s,
          symbol: data["symbol"] || "N/A",
          time: data["time"]&.to_i || Time.current.to_i,
          open: data["open"] || "0",
          high: data["high"] || "0",
          low: data["low"] || "0",
          close: data["close"] || "0",
          vol: data["vol"] || "0",
          tor: data["tor"] || "0",
          change: data["change"] || "0",
          color: data["color"] || "#FFFFF0"
        }
      end

      # 格式化24小时ticker
      def format_24h_ticker(market, data)
        {
          market_id: market.market_id,
          symbol: data["symbol"] || market.market_id.to_s,
          intvl: 1440,  # 24小时
          values: [
            data["time"]&.to_i || Time.current.to_i,          # time
            data["open"].to_s,                                # open (Wei)
            data["high"].to_s,                                # high (Wei)
            data["low"].to_s,                                 # low (Wei)
            data["close"].to_s,                               # close (Wei)
            data["vol"]&.to_f&.round(2) || 0,                # volume (数量不需要转换)
            data["tor"].to_s,                                 # turnover (Wei)
            data["open"].to_s                                 # reference price (Wei)
          ],
          change: data["change"] || "0",
          color: data["color"] || "#FFFFF0"
        }
      end

      def format_stat_ticker(market, stat)
        {
          market_id: market.market_id,
          symbol: market.market_id.to_s,
          intvl: 1440,
          values: [
            stat.window_end_ts,
            stat.open_price_wei.to_s,
            stat.high_price_wei.to_s,
            stat.low_price_wei.to_s,
            stat.close_price_wei.to_s,
            stat.volume.to_f,
            stat.turnover_wei.to_s,
            stat.open_price_wei.to_s
          ],
          change: calculate_change(stat.close_price_wei.to_f, stat.open_price_wei.to_f),
          color: get_color(stat.close_price_wei.to_f, stat.open_price_wei.to_f)
        }
      end
    end
  end
end
