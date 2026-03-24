# frozen_string_literal: true

class Matching::Execution::RoundMatcher
  def initialize(order_sanitizer:, numeric_parser:, matching_error_logger:, combination_finder:,
                 ask_fill_breakdown_builder:, mxn_enabled:, mxn_matcher:, current_bid_loader:)
    @order_sanitizer = order_sanitizer
    @numeric_parser = numeric_parser
    @matching_error_logger = matching_error_logger
    @combination_finder = combination_finder
    @ask_fill_breakdown_builder = ask_fill_breakdown_builder
    @mxn_enabled = mxn_enabled
    @mxn_matcher = mxn_matcher
    @current_bid_loader = current_bid_loader
  end

  def match_orders(bids, asks, max_rounds:)
    matched_orders = []

    bids = @order_sanitizer.call(bids, 'bids')
    asks = @order_sanitizer.call(asks, 'asks')

    Rails.logger.info "[match_orders] 开始撮合: Bids=#{bids.size}, Asks=#{asks.size}"
    return [] if bids.empty? || asks.empty?

    if @mxn_enabled.call
      Rails.logger.info "[match_orders] MxN模式开启：尝试全局精确撮合"
      return @mxn_matcher.call(bids, asks)
    end

    max_rounds.times do |round|
      Rails.logger.info "[match_orders] 第#{round + 1}轮撮合"
      round_matched = false

      bids.each do |(bid_price, bid_qty, bid_hash, _identifier, _created_at)|
        Rails.logger.info "[match_orders] 处理买单: price=#{bid_price}, qty=#{bid_qty}, hash=#{bid_hash[0..10]}..."

        bid_price_num, bid_qty_num = normalize_bid(bid_price, bid_qty, bid_hash, asks)
        next if bid_price_num.nil? || bid_qty_num.nil?

        matching_combination = @combination_finder.call(
          bids,
          asks,
          0,
          {
            current_qty: 0,
            match_completed: false,
            remaining_qty: bid_qty_num,
            current_orders: [],
            bid_hash: bid_hash
          }
        )

        next unless matching_combination && matching_combination[:match_completed]

        actual_bid_filled = matching_combination[:current_qty] || bid_qty_num
        ask_fills = @ask_fill_breakdown_builder.call(
          matching_combination[:current_orders],
          asks,
          actual_bid_filled
        )

        matched_orders << {
          'side' => 'Offer',
          'bid' => [bid_price_num, bid_qty_num, bid_hash],
          'ask' => matching_combination,
          'partial_match' => false,
          'bid_filled' => actual_bid_filled,
          'bid_total' => bid_qty_num,
          'ask_fills' => ask_fills
        }

        bids.reject! { |(_bp, _bq, oh, _)| oh == bid_hash }
        matching_combination[:current_orders].each do |ask_hash|
          asks.reject! { |(_ap, _aq, oh, _)| oh == ask_hash }
        end

        round_matched = true
        break
      end

      break unless round_matched
    end

    matched_orders
  end

  private

  def normalize_bid(bid_price, bid_qty, bid_hash, asks)
    @current_bid_loader.call(bid_hash)

    bid_qty_num = bid_qty.is_a?(String) ? @numeric_parser.call(bid_qty, 'bid.qty') : bid_qty
    bid_price_num = bid_price.is_a?(String) ? @numeric_parser.call(bid_price, 'bid.price') : bid_price
    return [bid_price_num, bid_qty_num] if asks.any?

    [nil, nil]
  rescue => e
    @matching_error_logger.call(e, bid_hash, bid_qty, asks)
    [nil, nil]
  end
end
