# frozen_string_literal: true

require 'ostruct'

module MarketData
  # 市场摘要服务
  # 提供市场的汇总统计信息：买卖盘数量、总量的 best bid/ask 等
  class MarketSummaryService
    SUMMARY_COLUMNS = %i[
      id
      market_id
      order_hash
      order_direction
      start_price
      end_price
      start_time
      end_time
      consideration_start_amount
      consideration_end_amount
      offer_start_amount
      offer_end_amount
      total_filled
      total_size
    ].freeze

    # 单个市场摘要
    # @param market_id [Integer] 市场ID
    # @return [Hash] 市场摘要数据
    def call(market_id)
      Rails.logger.info "[MarketSummaryService] 生成市场摘要 (market_id=#{market_id})"

      # 查询有效订单
      summary_data = build_summaries_from_sql([market_id])[market_id.to_i] || default_summary(market_id)

      bid_count = summary_data[:bid_count]
      ask_count = summary_data[:ask_count]
      bid_amount = summary_data[:bid_amount]
      ask_amount = summary_data[:ask_amount]
      best_bid_price = summary_data[:best_bid_price]
      best_bid_order_hash = summary_data[:best_bid_order_hash]
      best_ask_price = summary_data[:best_ask_price]
      best_ask_order_hash = summary_data[:best_ask_order_hash]

      spread, spread_percent = calculate_spread(best_bid_price, best_ask_price)

      last_fill = fetch_latest_fills([market_id])[market_id.to_i]
      last_trade_price = last_fill ? calculate_price_from_row(last_fill) : nil
      last_trade_at = last_fill ? resolve_fill_time(last_fill) : nil
      if last_fill.nil?
        Rails.logger.debug "[MarketSummaryService] ⚠️ 最近成交缺失，使用空值 (market_id=#{market_id})"
      end

      now = Time.current
      ts_24h = (now - 24.hours).to_i
      preclose_map = MarketData::PrecloseCalculator.batch_calculate_for_timestamp([market_id], ts_24h)
      preclose_price = preclose_map["preclose:#{market_id}:#{ts_24h}"]
      price_change_24h_pct = calculate_change_pct(last_trade_price, preclose_price)
      if preclose_price.to_d.zero?
        Rails.logger.debug "[MarketSummaryService] ⚠️ 24h前成交缺失，变化百分比为空 (market_id=#{market_id}, preclose=#{preclose_price})"
      end

      market = Trading::Market.find_by(market_id: market_id)

      summary = {
        market_id: market_id.to_s,
        item_id: market&.item_id,
        bid_count: bid_count,
        ask_count: ask_count,
        bid_amount: decimal_to_plain_string(bid_amount),
        ask_amount: decimal_to_plain_string(ask_amount),
        best_bid_price: decimal_to_plain_string(best_bid_price),
        best_bid_order_hash: best_bid_order_hash,
        best_ask_price: decimal_to_plain_string(best_ask_price),
        best_ask_order_hash: best_ask_order_hash,
        spread: decimal_to_plain_string(spread),
        spread_percent: spread_percent,
        last_trade_price: decimal_to_plain_string(last_trade_price),
        last_trade_at: last_trade_at,
        price_change_24h_pct: price_change_24h_pct,
        updated_at: Time.current.iso8601
      }

      Rails.logger.info "[MarketSummaryService] 市场摘要生成完成 (market_id=#{market_id}): bids=#{bid_count}(#{bid_amount}), asks=#{ask_count}(#{ask_amount})"

      summary
    end

    # 批量生成市场摘要
    # @param market_ids [Array<Integer>] 市场ID数组
    # @return [Hash] market_id => summary 的映射
    def batch_call(market_ids)
      Rails.logger.info "[MarketSummaryService] 批量生成市场摘要 (count=#{market_ids.size})"

      return {} if market_ids.empty?

      markets_by_id = Trading::Market
        .where(market_id: market_ids)
        .select(:market_id, :item_id)
        .index_by(&:market_id)

      # 批量查询所有市场的有效订单
      summaries = build_summaries_from_sql(market_ids)

      latest_fills = fetch_latest_fills(market_ids)
      ts_24h = (Time.current - 24.hours).to_i
      preclose_map = MarketData::PrecloseCalculator.batch_calculate_for_timestamp(market_ids, ts_24h)

      market_ids.each do |market_id|
        summary = summaries[market_id.to_i]
        next unless summary

        best_bid_price = summary[:best_bid_price]
        best_ask_price = summary[:best_ask_price]

        spread, spread_percent = calculate_spread(best_bid_price, best_ask_price)

        summary[:bid_amount] = decimal_to_plain_string(summary[:bid_amount]) || '0'
        summary[:ask_amount] = decimal_to_plain_string(summary[:ask_amount]) || '0'
        summary[:spread] = decimal_to_plain_string(spread)
        summary[:spread_percent] = spread_percent

        last_fill = latest_fills[market_id.to_i]
        last_trade_price = last_fill ? calculate_price_from_row(last_fill) : nil
        last_trade_at = last_fill ? resolve_fill_time(last_fill) : nil
        preclose_price = preclose_map["preclose:#{market_id}:#{ts_24h}"]
        price_change_24h_pct = calculate_change_pct(last_trade_price, preclose_price)

        if last_fill.nil?
          Rails.logger.debug "[MarketSummaryService] ⚠️ 最近成交缺失，使用空值 (market_id=#{market_id})"
        end
        if preclose_price.to_d.zero?
          Rails.logger.debug "[MarketSummaryService] ⚠️ 24h前成交缺失，变化百分比为空 (market_id=#{market_id}, preclose=#{preclose_price})"
        end

        summary[:last_trade_price] = decimal_to_plain_string(last_trade_price)
        summary[:last_trade_at] = last_trade_at
        summary[:price_change_24h_pct] = price_change_24h_pct
        summary[:updated_at] = Time.current.iso8601
        market = markets_by_id[market_id.to_s]
        summary[:market_id] = market_id.to_s
        summary[:item_id] = market&.item_id
      end

      Rails.logger.info "[MarketSummaryService] 批量市场摘要生成完成 (count=#{market_ids.size})"

      summaries
    end

    private

    def default_summary(market_id)
      {
        market_id: market_id.to_i,
        bid_count: 0,
        ask_count: 0,
        bid_amount: 0,
        ask_amount: 0,
        best_bid_price: nil,
        best_bid_order_hash: nil,
        best_ask_price: nil,
        best_ask_order_hash: nil
      }
    end

    def build_summaries_from_sql(market_ids)
      summaries = {}
      market_ids.each { |market_id| summaries[market_id.to_i] = default_summary(market_id) }

      return summaries if market_ids.blank?

      aggregates = query_order_aggregates(market_ids)
      best_bids = query_best_prices(market_ids, 'Offer', :desc)
      best_asks = query_best_prices(market_ids, 'List', :asc)

      aggregates.each do |row|
        market_id = row['market_id'].to_i
        summary = summaries[market_id]
        next unless summary

        summary[:bid_count] = row['bid_count'].to_i
        summary[:ask_count] = row['ask_count'].to_i
        summary[:bid_amount] = decimal_to_plain_string(row['bid_amount']) || '0'
        summary[:ask_amount] = decimal_to_plain_string(row['ask_amount']) || '0'
      end

      best_bids.each do |row|
        market_id = row['market_id'].to_i
        summary = summaries[market_id]
        next unless summary

        summary[:best_bid_price] = decimal_to_plain_string(row['current_price'])
        summary[:best_bid_order_hash] = row['order_hash']
      end

      best_asks.each do |row|
        market_id = row['market_id'].to_i
        summary = summaries[market_id]
        next unless summary

        summary[:best_ask_price] = decimal_to_plain_string(row['current_price'])
        summary[:best_ask_order_hash] = row['order_hash']
      end

      summaries
    rescue => e
      Rails.logger.error "[MarketSummaryService] SQL aggregation failed: #{e.message}"
      summaries
    end

    def query_order_aggregates(market_ids)
      sql = <<~SQL
        WITH base AS (
          #{base_order_sql(market_ids)}
        )
        SELECT
          market_id,
          SUM(CASE WHEN order_direction = 'Offer' THEN 1 ELSE 0 END) AS bid_count,
          SUM(CASE WHEN order_direction = 'List' THEN 1 ELSE 0 END) AS ask_count,
          COALESCE(SUM(CASE WHEN order_direction = 'Offer' THEN unfilled_qty ELSE 0 END), 0) AS bid_amount,
          COALESCE(SUM(CASE WHEN order_direction = 'List' THEN unfilled_qty ELSE 0 END), 0) AS ask_amount
        FROM base
        GROUP BY market_id
      SQL

      ActiveRecord::Base.connection.exec_query(sql).to_a
    end

    def query_best_prices(market_ids, direction, order)
      order_clause = order == :desc ? 'DESC' : 'ASC'
      sql = <<~SQL
        WITH base AS (
          #{base_order_sql(market_ids)}
        )
        SELECT DISTINCT ON (market_id)
          market_id,
          order_hash,
          current_price
        FROM base
        WHERE order_direction = #{ActiveRecord::Base.connection.quote(direction)}
          AND current_price IS NOT NULL
        ORDER BY market_id, current_price #{order_clause} NULLS LAST, id DESC
      SQL

      ActiveRecord::Base.connection.exec_query(sql).to_a
    end

    def base_order_sql(market_ids)
      ids = market_ids.map { |id| ActiveRecord::Base.connection.quote(id.to_s) }.join(',')
      <<~SQL
        SELECT
          id,
          market_id,
          order_hash,
          order_direction,
          start_price,
          end_price,
          start_time,
          end_time,
          consideration_start_amount,
          consideration_end_amount,
          offer_start_amount,
          offer_end_amount,
          total_filled,
          total_size,
          current_price,
          unfilled_qty
        FROM (
          SELECT
            id,
            market_id,
            order_hash,
            order_direction,
            start_price::numeric AS start_price,
            end_price::numeric AS end_price,
            start_time::numeric AS start_time,
            end_time::numeric AS end_time,
            consideration_start_amount::numeric AS consideration_start_amount,
            consideration_end_amount::numeric AS consideration_end_amount,
            offer_start_amount::numeric AS offer_start_amount,
            offer_end_amount::numeric AS offer_end_amount,
            total_filled::numeric AS total_filled,
            total_size::numeric AS total_size,
            CASE
              WHEN (end_time::numeric - start_time::numeric) <= 0 THEN 0
              ELSE GREATEST(
                0,
                LEAST(
                  1,
                  ((EXTRACT(EPOCH FROM NOW())::numeric - start_time::numeric) /
                  NULLIF(end_time::numeric - start_time::numeric, 0))
                )
              )
            END AS time_progress,
            CASE
              WHEN total_size::numeric <= 0 THEN 0
              ELSE GREATEST(
                0,
                LEAST(1, total_filled::numeric / NULLIF(total_size::numeric, 0))
              )
            END AS fill_progress
          FROM trading_orders
          WHERE market_id IN (#{ids})
            AND order_direction IN ('Offer', 'List')
            AND onchain_status IN ('pending', 'validated', 'partially_filled')
            AND offchain_status IN ('active', 'matching')
        ) base_raw
        CROSS JOIN LATERAL (
          SELECT
            (base_raw.start_price + (base_raw.end_price - base_raw.start_price) * base_raw.time_progress) AS current_price,
            (
              CASE
                WHEN base_raw.order_direction = 'Offer'
                  THEN base_raw.consideration_start_amount + (base_raw.consideration_end_amount - base_raw.consideration_start_amount) * base_raw.time_progress
                ELSE base_raw.offer_start_amount + (base_raw.offer_end_amount - base_raw.offer_start_amount) * base_raw.time_progress
              END
            ) * (1 - base_raw.fill_progress) AS unfilled_qty
        ) calc
      SQL
    end

    def calculate_spread(best_bid_price, best_ask_price)
      return [nil, nil] if best_bid_price.nil? || best_ask_price.nil?

      bid = best_bid_price.to_d
      ask = best_ask_price.to_d
      return [nil, nil] if bid.zero?

      spread_value = decimal_to_plain_string(ask - bid)
      spread_percent = decimal_to_plain_string(((ask - bid) / bid) * 100)

      [spread_value, spread_percent]
    end

    def fetch_latest_fills(market_ids)
      return {} if market_ids.blank?

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
        ORDER BY market_id,
                 COALESCE(block_timestamp, EXTRACT(EPOCH FROM created_at)) DESC,
                 id DESC
      SQL

      rows = ActiveRecord::Base.connection.exec_query(sql).to_a
      rows.index_by { |row| row['market_id'].to_i }
    end

    def calculate_price_from_row(row)
      fill = OpenStruct.new(
        price_distribution: row['price_distribution'],
        filled_amount: row['filled_amount']
      )
      MarketData::PriceCalculator.calculate_price_from_fill(fill)
    end

    def resolve_fill_time(row)
      ts = row['block_timestamp']
      return Time.at(ts.to_i).iso8601 if ts.present?

      created_at = row['created_at']
      return created_at.iso8601 if created_at.respond_to?(:iso8601)

      nil
    end

    def calculate_change_pct(current_price, preclose_price)
      return nil if current_price.nil?
      current = current_price.to_d
      return nil if current.zero?

      base = preclose_price.to_d
      return nil if base.zero?

      decimal_to_plain_string((((current - base) / base) * 100).round(2))
    end

    def decimal_to_plain_string(value)
      return nil if value.nil?

      BigDecimal(value.to_s).to_s('F')
    rescue ArgumentError, TypeError
      value.to_s
    end
  end
end
