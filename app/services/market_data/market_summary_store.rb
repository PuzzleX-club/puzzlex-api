# frozen_string_literal: true

module MarketData
  # 市场摘要存储服务（PG 权威层）
  class MarketSummaryStore
    class << self
      def upsert_summary(summary)
        upsert_summaries([summary])
      end

      def upsert_summaries(summaries)
        return if summaries.blank?

        now = Time.current
        rows = summaries.map do |summary|
          {
            market_id: summary[:market_id].to_s,
            item_id: summary[:item_id],
            bid_count: summary[:bid_count] || 0,
            ask_count: summary[:ask_count] || 0,
            bid_amount: decimal_to_plain_string(summary[:bid_amount]) || '0',
            ask_amount: decimal_to_plain_string(summary[:ask_amount]) || '0',
            best_bid_price: decimal_to_plain_string(summary[:best_bid_price]),
            best_ask_price: decimal_to_plain_string(summary[:best_ask_price]),
            best_bid_order_hash: summary[:best_bid_order_hash],
            best_ask_order_hash: summary[:best_ask_order_hash],
            spread: decimal_to_plain_string(summary[:spread]),
            last_trade_price: decimal_to_plain_string(summary[:last_trade_price]),
            last_trade_at: summary[:last_trade_at],
            price_change_24h_pct: decimal_to_plain_string(summary[:price_change_24h_pct]),
            dirty: false,
            dirty_at: nil,
            created_at: now,
            updated_at: now
          }
        end

        Trading::MarketSummary.upsert_all(rows, unique_by: :index_trading_market_summaries_on_market_id)
      end

      def mark_dirty(market_id)
        return if market_id.blank?

        now = Time.current
        rows = [{
          market_id: market_id.to_s,
          dirty: true,
          dirty_at: now,
          created_at: now,
          updated_at: now
        }]

        Trading::MarketSummary.upsert_all(rows, unique_by: :index_trading_market_summaries_on_market_id)
      end

      def fetch_summaries(market_ids)
        return {} if market_ids.blank?

        Trading::MarketSummary
          .where(market_id: market_ids.map(&:to_s))
          .index_by(&:market_id)
      end

      def serialize(record)
        return nil if record.nil?

        spread_percent = calculate_spread_percent(record.best_bid_price, record.best_ask_price)

        {
          market_id: record.market_id.to_i,
          item_id: record.item_id,
          bid_count: record.bid_count || 0,
          ask_count: record.ask_count || 0,
          bid_amount: decimal_to_plain_string(record.bid_amount) || '0',
          ask_amount: decimal_to_plain_string(record.ask_amount) || '0',
          best_bid_price: decimal_to_plain_string(record.best_bid_price),
          best_bid_order_hash: record.best_bid_order_hash,
          best_ask_price: decimal_to_plain_string(record.best_ask_price),
          best_ask_order_hash: record.best_ask_order_hash,
          spread: decimal_to_plain_string(record.spread),
          last_trade_price: decimal_to_plain_string(record.last_trade_price),
          last_trade_at: record.last_trade_at&.iso8601,
          price_change_24h_pct: decimal_to_plain_string(record.price_change_24h_pct),
          spread_percent: spread_percent,
          updated_at: record.updated_at&.iso8601
        }
      end

      def serialize_many(records)
        records.map { |record| serialize(record) }.compact
      end

      def fetch_page(page, per)
        offset = (page - 1) * per
        Trading::MarketSummary
          .order(updated_at: :desc)
          .offset(offset)
          .limit(per)
      end

      def total_count
        Trading::MarketSummary.count
      end

      def calculate_spread_percent(best_bid_price, best_ask_price)
        return nil if best_bid_price.nil? || best_ask_price.nil?

        bid = best_bid_price.to_d
        ask = best_ask_price.to_d
        return nil if bid.zero?

        decimal_to_plain_string(((ask - bid) / bid) * 100)
      end
      private :calculate_spread_percent

      def decimal_to_plain_string(value)
        return nil if value.nil?

        BigDecimal(value.to_s).to_s('F')
      rescue ArgumentError, TypeError
        value.to_s
      end
      private :decimal_to_plain_string
    end
  end
end
