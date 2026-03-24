# frozen_string_literal: true

require 'ostruct'

module MarketData
  # 前收盘价计算服务
  # 统一处理前收盘价的计算逻辑，支持缓存优化
  class PrecloseCalculator
    class << self
      # 计算前收盘价
      # @param market_id [Integer] 市场ID
      # @param timestamp [Integer] 时间戳
      # @return [Float] 前收盘价（wei）
      def calculate(market_id, timestamp)
        # 使用缓存优化频繁查询
        cache_key = "preclose:#{market_id}:#{timestamp}"
        
        Rails.cache.fetch(cache_key, expires_in: 1.hour) do
          compute_from_database(market_id, timestamp)
        end
      end
      
      # 批量计算前收盘价
      # @param market_timestamps [Array<Hash>] [{market_id: 1, timestamp: 123}, ...]
      # @return [Hash] { "market_id:timestamp" => price }
      def batch_calculate(market_timestamps)
        # 先检查缓存
        cache_keys = market_timestamps.map { |item| "preclose:#{item[:market_id]}:#{item[:timestamp]}" }
        cached_results = Rails.cache.read_multi(*cache_keys)
        
        # 计算未缓存的数据
        uncached_items = market_timestamps.reject do |item|
          cached_results.key?("preclose:#{item[:market_id]}:#{item[:timestamp]}")
        end
        
        # 批量查询数据库
        new_results = {}
        uncached_items.each do |item|
          price = compute_from_database(item[:market_id], item[:timestamp])
          cache_key = "preclose:#{item[:market_id]}:#{item[:timestamp]}"
          new_results[cache_key] = price
          Rails.cache.write(cache_key, price, expires_in: 1.hour)
        end
        
        # 合并结果
        cached_results.merge(new_results)
      end

      # 批量计算同一时间点的前收盘价（优化单次请求多市场场景）
      # @param market_ids [Array<Integer>]
      # @param timestamp [Integer]
      # @return [Hash] { "preclose:market_id:timestamp" => price }
      def batch_calculate_for_timestamp(market_ids, timestamp)
        return {} if market_ids.blank?

        cache_keys = market_ids.map { |market_id| "preclose:#{market_id}:#{timestamp}" }
        cached_results = Rails.cache.read_multi(*cache_keys)

        uncached_ids = market_ids.reject do |market_id|
          cached_results.key?("preclose:#{market_id}:#{timestamp}")
        end

        new_results = {}
        if uncached_ids.any?
          rows = query_preclose_fills(uncached_ids, timestamp)
          rows_by_market = rows.index_by { |row| row['market_id'].to_i }

          uncached_ids.each do |market_id|
            row = rows_by_market[market_id.to_i]
            price = row ? calculate_price_from_row(row) : 0.0
            cache_key = "preclose:#{market_id}:#{timestamp}"
            new_results[cache_key] = price
            Rails.cache.write(cache_key, price, expires_in: 1.hour)
          end
        end

        cached_results.merge(new_results)
      end
      
      # 清除缓存
      def clear_cache(market_id = nil)
        if market_id
          Rails.cache.delete_matched("preclose:#{market_id}:*")
        else
          Rails.cache.delete_matched("preclose:*")
        end
      end
      
      private
      
      # 从数据库计算前收盘价
      def compute_from_database(market_id, timestamp)
        fill = Trading::OrderFill
                 .where(market_id: market_id)
                 .where("block_timestamp <= ?", timestamp)
                 .order(block_timestamp: :desc)
                 .limit(1)
                 .first
        
        return 0.0 if fill.nil?
        
        PriceCalculator.calculate_price_from_fill(fill)
      end

      def query_preclose_fills(market_ids, timestamp)
        ids = market_ids.map { |id| ActiveRecord::Base.connection.quote(id.to_s) }.join(',')
        sql = <<~SQL
          SELECT DISTINCT ON (market_id)
            market_id,
            price_distribution,
            filled_amount,
            block_timestamp,
            created_at
          FROM trading_order_fills
          WHERE market_id IN (#{ids})
            AND COALESCE(block_timestamp, EXTRACT(EPOCH FROM created_at)) <= #{timestamp.to_i}
          ORDER BY market_id,
                   COALESCE(block_timestamp, EXTRACT(EPOCH FROM created_at)) DESC,
                   id DESC
        SQL

        ActiveRecord::Base.connection.exec_query(sql).to_a
      end

      def calculate_price_from_row(row)
        fill = OpenStruct.new(
          price_distribution: row['price_distribution'],
          filled_amount: row['filled_amount']
        )
        PriceCalculator.calculate_price_from_fill(fill)
      end
    end
  end
end
