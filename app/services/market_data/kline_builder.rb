# frozen_string_literal: true

require 'bigdecimal'

module MarketData
  # K线数据构建服务
  # 统一K线数据的生成逻辑
  class KlineBuilder
    class << self
      # 构建K线数据
      # @param market_id [Integer] 市场ID
      # @param interval [Integer] 时间间隔（秒）
      # @param start_time [Integer] 开始时间戳
      # @param end_time [Integer] 结束时间戳
      # @return [Array] [timestamp, open, high, low, close, volume, turnover]
      def build(market_id, interval, start_time, end_time)
        fills = fetch_fills(market_id, start_time, end_time)
        
        if fills.empty?
          default_price = fetch_previous_close(market_id, start_time, interval)
          build_empty_kline(end_time, default_price)
        else
          build_kline_from_fills(fills, end_time)
        end
      end
      
      # 批量构建K线数据
      # @param requests [Array<Hash>] 请求数组
      # @return [Hash] { "market_id:interval" => kline_data }
      def batch_build(requests)
        requests.each_with_object({}) do |request, result|
          key = "#{request[:market_id]}:#{request[:interval]}"
          result[key] = build(
            request[:market_id],
            request[:interval],
            request[:start_time],
            request[:end_time]
          )
        end
      end
      
      # 构建实时K线数据（包含当前未完成的K线）
      # @param interval [Integer] 时间间隔（秒）
      def build_realtime(market_id, interval)
        now = Time.current.to_i
        aligned_time = align_to_interval(now, interval)
        start_time = aligned_time
        end_time = aligned_time + interval

        # 尝试获取当前周期的成交数据
        fills = fetch_fills(market_id, start_time, end_time)

        if fills.empty?
          # 无成交时，尝试获取最近的价格作为参考
          last_price = fetch_previous_close(market_id, start_time, interval) || fetch_last_price(market_id) || 0
          build_empty_kline(aligned_time, last_price)
        else
          build_kline_from_fills(fills, aligned_time)
        end
      end

      # 构建双窗口K线数据（当前窗口 + 上一个窗口）
      # @param market_id [Integer] 市场ID
      # @param interval [Integer] 时间间隔（秒）
      # @return [Hash] { current: Array, previous: Hash }
      def build_with_previous(market_id, interval)
        now = Time.current.to_i
        current_window_start = align_to_interval(now, interval)
        previous_window_start = current_window_start - interval

        Rails.logger.info "[KlineBuilder] build_with_previous - market: #{market_id}, interval: #{interval}秒"
        Rails.logger.info "[KlineBuilder] 当前时间: #{Time.at(now).strftime('%H:%M:%S')}"
        Rails.logger.info "[KlineBuilder] 当前窗口: #{Time.at(current_window_start).strftime('%H:%M:%S')}"
        Rails.logger.info "[KlineBuilder] 上一窗口: #{Time.at(previous_window_start).strftime('%H:%M:%S')}"

        # 构建当前窗口的实时K线（非final）
        current_kline = build_realtime(market_id, interval)

        # 从数据库获取上一个窗口的final K线
        previous_kline_record = Trading::Kline
          .where(market_id: market_id, interval: interval)
          .where(timestamp: previous_window_start)
          .first

        previous_kline = if previous_kline_record
          {
            window_start: previous_window_start,
            open: previous_kline_record.open,
            high: previous_kline_record.high,
            low: previous_kline_record.low,
            close: previous_kline_record.close,
            volume: previous_kline_record.volume.to_f,
            turnover: previous_kline_record.turnover,
            is_final: true
          }
        else
          nil
        end

        {
          current: {
            window_start: current_window_start,
            data: current_kline,
            is_final: false
          },
          previous: previous_kline
        }
      end
      
      private
      
      # 获取时间范围内的成交记录
      def fetch_fills(market_id, start_time, end_time)
        Trading::OrderFill
          .where(market_id: market_id)
          .where("block_timestamp > ? AND block_timestamp <= ?", start_time, end_time)
          .order(:block_timestamp)
          .includes(:order) # 预加载关联，避免N+1
      end
      
      # 从成交记录构建K线
      def build_kline_from_fills(fills, end_time)
        prices_and_volumes = extract_prices_and_volumes(fills)
        return build_empty_kline(end_time) if prices_and_volumes.empty?
        
        prices = prices_and_volumes.map { |pv| pv[:price] }
        volumes = prices_and_volumes.map { |pv| pv[:volume] }

        open_price = prices.first
        close_price = prices.last
        high_price = prices.max
        low_price = prices.min
        total_volume = volumes.reduce(BigDecimal('0')) { |sum, v| sum + v }
        turnover = prices_and_volumes.reduce(BigDecimal('0')) do |sum, pv|
          sum + (pv[:price] * pv[:volume])
        end

        [
          end_time,
          open_price.to_i,
          high_price.to_i,
          low_price.to_i,
          close_price.to_i,
          total_volume.to_s('F'),
          turnover.to_s('F')
        ]
      end
      
      # 提取价格和交易量
      def extract_prices_and_volumes(fills)
        fills.filter_map do |fill|
          price = PriceCalculator.calculate_price_from_fill(fill)
          next if price.zero?
          
          {
            price: BigDecimal(price.to_s),
            volume: BigDecimal(fill.filled_amount.to_s),
            timestamp: fill.block_timestamp
          }
        end
      end
      

      # 获取市场最近成交价格
      def fetch_last_price(market_id)
        last_fill = Trading::OrderFill
          .where(market_id: market_id)
          .order(created_at: :desc)
          .first

        if last_fill
          # 从price_distribution或关联的order中获取价格
          price = PriceCalculator.calculate_price_from_fill(last_fill)
          BigDecimal(price.to_s)
        else
          0
        end
      end

      # 构建空K线
      def build_empty_kline(timestamp, default_price = 0)
        default = BigDecimal(default_price.to_s).to_i
        [timestamp, default, default, default, default, '0', 0]
      end

      # 时间对齐
      # @param interval [Integer] 时间间隔（秒）
      def align_to_interval(timestamp, interval)
        (timestamp / interval) * interval
      end

      # 获取上一根K线的收盘价，若不存在则回退到最近成交价
      # @param interval [Integer] 时间间隔（秒）
      def fetch_previous_close(market_id, start_time, interval)
        interval_seconds = interval.to_i
        previous_kline = Trading::Kline
          .where(market_id: market_id, interval: interval_seconds)
          .where("timestamp < ?", start_time)
          .order(timestamp: :desc)
          .limit(1)
          .first

        return previous_kline&.close unless previous_kline.nil?

        fetch_last_price(market_id)
      end
    end
  end
end
