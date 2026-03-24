# frozen_string_literal: true

module MarketData
  # 根据 Trading::MarketFillEvent 维护 24 小时窗口的 Trading::MarketIntradayStat
  class MarketIntradayAggregator
    WINDOW_SECONDS = 24.hours.to_i

    def initialize(market_id, reference_time: Time.current.to_i)
      @market_id = market_id
      @reference_time = reference_time
    end

    def call
      ActiveRecord::Base.transaction do
        events = events_in_window

        if events.any?
          persist_stats_with_trades(events)
        else
          persist_stats_without_trades
        end

        cleanup_old_events
      end
    end

    private

    attr_reader :market_id, :reference_time

    def window_end
      @window_end ||= reference_time
    end

    def window_start
      @window_start ||= window_end - WINDOW_SECONDS
    end

    def events_in_window
      Trading::MarketFillEvent.where(market_id: market_id)
                     .where(block_timestamp: window_start..window_end)
                     .order(:block_timestamp)
    end

    def persist_stats_with_trades(events)
      ohlc = build_ohlc(events)

      Trading::MarketIntradayStat.upsert({
        market_id: market_id,
        window_start_ts: window_start,
        window_end_ts: window_end,
        open_price_wei: ohlc[:open],
        high_price_wei: ohlc[:high],
        low_price_wei: ohlc[:low],
        close_price_wei: ohlc[:close],
        last_price_wei: ohlc[:close],
        volume: ohlc[:volume],
        turnover_wei: ohlc[:turnover],
        fill_count: events.size,
        has_trade: true,
        last_processed_event_id: events.last.id,
        updated_at: Time.current,
        created_at: Time.current
      }, unique_by: :market_id)
    end

    def persist_stats_without_trades
      last_price = existing_last_price || latest_price_from_history || 0

      Trading::MarketIntradayStat.upsert({
        market_id: market_id,
        window_start_ts: window_start,
        window_end_ts: window_end,
        open_price_wei: last_price,
        high_price_wei: last_price,
        low_price_wei: last_price,
        close_price_wei: last_price,
        last_price_wei: last_price,
        volume: 0,
        turnover_wei: 0,
        fill_count: 0,
        has_trade: false,
        updated_at: Time.current,
        created_at: Time.current
      }, unique_by: :market_id)
    end

    def existing_last_price
      Trading::MarketIntradayStat.where(market_id: market_id).pick(:last_price_wei)
    end

    def latest_price_from_history
      last_fill = Trading::OrderFill.where(market_id: market_id)
                                    .order(block_timestamp: :desc)
                                    .first
      return unless last_fill

      MarketData::PriceCalculator.calculate_price_from_fill(last_fill)
    end

    def cleanup_old_events
      Trading::MarketFillEvent.where(market_id: market_id)
                     .where('block_timestamp < ?', window_start)
                     .delete_all
    end

    def build_ohlc(events)
      prices = events.map(&:price_wei)

      {
        open: prices.first,
        high: prices.max,
        low: prices.min,
        close: prices.last,
        volume: events.sum(&:filled_amount),
        turnover: events.sum(&:turnover_wei)
      }
    end
  end
end
