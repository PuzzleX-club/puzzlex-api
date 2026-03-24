# frozen_string_literal: true

class Matching::Execution::MxnMatcher
  def initialize(numeric_parser:, search_options_provider:, runtime_options_provider:)
    @numeric_parser = numeric_parser
    @search_options_provider = search_options_provider
    @runtime_options_provider = runtime_options_provider
  end

  def match_orders(bids, asks)
    normalized_bids = normalize_bids(bids)
    normalized_asks = normalize_asks(asks)
    return [] if normalized_bids.empty? || normalized_asks.empty?

    runtime_options = @runtime_options_provider.call
    pending_bids = normalized_bids.sort_by { |bid| [-bid[:price], bid[:created_at]] }
    pending_asks = normalized_asks.sort_by { |ask| [ask[:price], ask[:created_at]] }
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + (runtime_options[:total_timeout_ms].to_f / 1000.0)
    all_matches = []
    round_index = 0

    while pending_bids.any? && pending_asks.any? && round_index < runtime_options[:max_rounds]
      break if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      round_index += 1
      search_result = run_window_search(pending_bids, pending_asks, runtime_options[:window_size])
      unless search_result[:feasible]
        search_result = run_window_search(pending_bids, pending_asks, runtime_options[:window_size] * 2)
      end

      unless search_result[:feasible]
        Rails.logger.info "[match_orders] MxN第#{round_index}轮无解：#{search_result[:exit_reason]}, flow_attempts=#{search_result[:flow_attempts]}"
        break
      end

      round_matches = build_matches_from_search_result(
        bids: pending_bids,
        asks: pending_asks,
        search_result: search_result
      )
      break if round_matches.empty?

      all_matches.concat(round_matches)
      consumed_bid_hashes = round_matches.each_with_object({}) do |match, memo|
        memo[match.dig('bid', 2).to_s] = true
      end
      consumed_ask_hashes = round_matches.each_with_object({}) do |match, memo|
        Array(match['ask_fills']).each { |fill| memo[fill['order_hash'].to_s] = true }
      end

      pending_bids = pending_bids.reject { |bid| consumed_bid_hashes[bid[:hash].to_s] }
      pending_asks = pending_asks.reject { |ask| consumed_ask_hashes[ask[:hash].to_s] }
    end

    all_matches
  end

  private

  def normalize_bids(bids)
    bids.map do |bid_price, bid_qty, bid_hash, identifier, created_at|
      {
        price: @numeric_parser.call(bid_price, "mxn.bid.price.#{bid_hash}"),
        qty: @numeric_parser.call(bid_qty, "mxn.bid.qty.#{bid_hash}").to_i,
        hash: bid_hash.to_s,
        identifier: identifier,
        created_at: created_at
      }
    end.select { |bid| bid[:qty] > 0 }
  end

  def normalize_asks(asks)
    asks.map do |ask_price, ask_qty, ask_hash, identifier, created_at|
      {
        price: @numeric_parser.call(ask_price, "mxn.ask.price.#{ask_hash}"),
        qty: @numeric_parser.call(ask_qty, "mxn.ask.qty.#{ask_hash}").to_i,
        hash: ask_hash.to_s,
        identifier: identifier,
        created_at: created_at
      }
    end.select { |ask| ask[:qty] > 0 }
  end

  def run_window_search(bids, asks, window_size)
    effective_window_size = [window_size.to_i, 1].max
    search_bids = bids.first(effective_window_size)
    search_asks = asks.first(effective_window_size)
    return { feasible: false, flow_attempts: 0, exit_reason: 'empty_window', flows: [] } if search_bids.empty? || search_asks.empty?

    Matching::Selection::ExecutableSubsetSearcher.new(
      bids: search_bids,
      asks: search_asks,
      options: @search_options_provider.call
    ).call
  end

  def build_matches_from_search_result(bids:, asks:, search_result:)
    flows = Array(search_result[:flows])
    asks_by_hash = asks.index_by { |ask| ask[:hash] }
    flows_by_bid_hash = flows.group_by { |flow| flow[:bid_hash].to_s }

    bids.each_with_object([]) do |bid, matched_orders|
      bid_flows = flows_by_bid_hash[bid[:hash].to_s]
      next if bid_flows.blank?

      ask_fills = bid_flows.filter_map do |flow|
        ask = asks_by_hash[flow[:ask_hash].to_s]
        next if ask.nil?
        qty = flow[:qty].to_f
        next if qty <= 0

        {
          'order_hash' => ask[:hash],
          'total_qty' => ask[:qty],
          'filled_qty' => qty
        }
      end
      next if ask_fills.empty?

      current_orders = ask_fills.map { |fill| fill['order_hash'] }.uniq
      bid_filled = ask_fills.sum { |fill| fill['filled_qty'].to_f }

      matched_orders << {
        'side' => 'Offer',
        'bid' => [bid[:price], bid[:qty], bid[:hash]],
        'ask' => {
          current_qty: bid[:qty],
          match_completed: true,
          remaining_qty: 0,
          current_orders: current_orders
        },
        'partial_match' => false,
        'bid_filled' => bid_filled,
        'bid_total' => bid[:qty],
        'ask_fills' => ask_fills
      }
    end
  end
end
