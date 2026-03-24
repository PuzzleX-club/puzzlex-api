# frozen_string_literal: true

# v2 fulfillment preflight validator.
# Goal: enforce strict full-fill invariants before data enters executor queue.
class Matching::Fulfillment::PreflightValidator
  EPSILON = 1e-9

  class ValidationError < StandardError; end

  def initialize(match_orders:, graph:, orders_by_hash:)
    @match_orders = match_orders || []
    @graph = graph || {}
    @orders_by_hash = orders_by_hash || {}
  end

  def validate!
    validate_fulfillment_components_bounds!

    fills_by_ask = build_fills_by_ask
    fills_by_bid = build_fills_by_bid
    fills_by_pair = build_fills_by_pair
    planned_fills_by_ask = build_planned_fills_by_ask

    @match_orders.each do |match|
      next unless match['side'] == 'Offer'

      validate_single_match!(match, fills_by_ask, fills_by_bid, fills_by_pair)
    end

    validate_global_ask_full_fill!(fills_by_ask, planned_fills_by_ask)

    true
  end

  private

  def validate_fulfillment_components_bounds!
    orders = Array(@graph[:orders]).map do |order|
      order.is_a?(Hash) ? (order[:parameters] || order['parameters'] || {}) : {}
    end
    return if orders.empty?

    Array(@graph[:fulfillments]).each_with_index do |fulfillment, fulfillment_index|
      next unless fulfillment.is_a?(Hash)

      validate_components!(
        components: Array(fulfillment[:offerComponents] || fulfillment['offerComponents']),
        orders: orders,
        side_key: :offer,
        fulfillment_index: fulfillment_index
      )
      validate_components!(
        components: Array(fulfillment[:considerationComponents] || fulfillment['considerationComponents']),
        orders: orders,
        side_key: :consideration,
        fulfillment_index: fulfillment_index
      )
    end
  end

  def validate_components!(components:, orders:, side_key:, fulfillment_index:)
    components.each do |component|
      next unless component.is_a?(Hash)

      order_index = (component[:orderIndex] || component['orderIndex']).to_i
      item_index = (component[:itemIndex] || component['itemIndex']).to_i
      order_params = orders[order_index]
      raise ValidationError, "invalid fulfillment orderIndex: #{order_index} at fulfillment[#{fulfillment_index}]" if order_params.nil?

      items = Array(order_params[side_key] || order_params[side_key.to_s])
      if item_index.negative? || item_index >= items.length
        raise ValidationError,
              "invalid fulfillment itemIndex: #{item_index} for #{side_key} at fulfillment[#{fulfillment_index}], order[#{order_index}]"
      end
    end
  end

  def validate_single_match!(match, fills_by_ask, fills_by_bid, fills_by_pair)
    bid_hash = match.dig('bid', 2).to_s
    ask_hashes = Array(match.dig('ask', :current_orders)).map(&:to_s)

    bid_total = to_f(match['bid_total'] || match.dig('bid', 1))
    bid_filled = to_f(match['bid_filled'] || bid_total)

    # Strict full-fill only: bid must be fully filled within this match.
    assert_close!(bid_filled, bid_total, "bid not fully filled: #{bid_hash} (filled=#{bid_filled}, total=#{bid_total})")

    # 每个 match 内 ask 都必须存在有效fill；单个 ask 可以在 MxN 下跨多个 bid 拆分。
    ask_sum = 0.0
    ask_hashes.each do |ask_hash|
      ask_filled = to_f(fills_by_ask[ask_hash])
      raise ValidationError, "missing ask fill edge: #{ask_hash}" if ask_filled <= 0

      ask_order = @orders_by_hash[ask_hash]
      raise ValidationError, "missing ask order in lookup: #{ask_hash}" if ask_order.nil?

      ask_fill_in_match = ask_fill_for_match(match, ask_hash)
      if ask_fill_in_match <= 0
        ask_fill_in_match = to_f(fills_by_pair[[bid_hash.to_s, ask_hash.to_s]])
      end
      raise ValidationError, "missing ask fill amount in match: bid=#{bid_hash}, ask=#{ask_hash}" if ask_fill_in_match <= 0
      ask_sum += ask_fill_in_match
    end

    # Quantity conservation: bid side total must equal sum of ask fills.
    assert_close!(ask_sum, bid_total, "quantity conservation violated for bid #{bid_hash} (ask_sum=#{ask_sum}, bid_total=#{bid_total})")

    bid_sum = to_f(fills_by_bid[bid_hash])
    assert_close!(bid_sum, bid_total, "bid aggregated fill mismatch: #{bid_hash} (filled=#{bid_sum}, total=#{bid_total})")
  end

  def build_fills_by_ask
    Array(@graph[:fills]).each_with_object(Hash.new(0.0)) do |fill, memo|
      next unless fill.is_a?(Hash)

      ask_hash = fill[:ask_hash].to_s
      filled_qty = to_f(fill[:filled_qty])
      next if ask_hash.empty? || filled_qty <= 0

      memo[ask_hash] += filled_qty
    end
  end

  def build_fills_by_bid
    Array(@graph[:fills]).each_with_object(Hash.new(0.0)) do |fill, memo|
      next unless fill.is_a?(Hash)

      bid_hash = fill[:bid_hash].to_s
      filled_qty = to_f(fill[:filled_qty])
      next if bid_hash.empty? || filled_qty <= 0

      memo[bid_hash] += filled_qty
    end
  end

  def build_fills_by_pair
    Array(@graph[:fills]).each_with_object(Hash.new(0.0)) do |fill, memo|
      next unless fill.is_a?(Hash)

      bid_hash = fill[:bid_hash].to_s
      ask_hash = fill[:ask_hash].to_s
      filled_qty = to_f(fill[:filled_qty])
      next if bid_hash.empty? || ask_hash.empty? || filled_qty <= 0

      memo[[bid_hash, ask_hash]] += filled_qty
    end
  end

  def ask_fill_for_match(match, ask_hash)
    fills = Array(match['ask_fills']).select { |fill| fill.is_a?(Hash) && fill['order_hash'].to_s == ask_hash.to_s }
    fills.sum { |fill| to_f(fill['filled_qty']) }
  end

  def validate_global_ask_full_fill!(fills_by_ask, planned_fills_by_ask)
    ask_hashes = @match_orders.each_with_object([]) do |match, memo|
      next unless match['side'] == 'Offer'
      memo.concat(Array(match.dig('ask', :current_orders)).map(&:to_s))
    end.uniq

    ask_hashes.each do |ask_hash|
      ask_order = @orders_by_hash[ask_hash]
      raise ValidationError, "missing ask order in lookup: #{ask_hash}" if ask_order.nil?

      ask_total = planned_total_for_ask(ask_hash, ask_order, planned_fills_by_ask)
      ask_filled = to_f(fills_by_ask[ask_hash])
      assert_close!(ask_filled, ask_total, "ask not fully filled: #{ask_hash} (filled=#{ask_filled}, total=#{ask_total})")
    end
  end

  def build_planned_fills_by_ask
    @match_orders.each_with_object(Hash.new(0.0)) do |match, memo|
      next unless match['side'] == 'Offer'

      Array(match['ask_fills']).each do |fill|
        next unless fill.is_a?(Hash)

        ask_hash = fill['order_hash'].to_s
        filled_qty = to_f(fill['filled_qty'])
        next if ask_hash.empty? || filled_qty <= 0

        memo[ask_hash] += filled_qty
      end
    end
  end

  def planned_total_for_ask(ask_hash, ask_order, planned_fills_by_ask)
    planned_total = to_f(planned_fills_by_ask[ask_hash])
    return planned_total if planned_total.positive?

    helper_total = Orders::OrderHelper.calculate_unfill_amount_from_order(ask_order).to_f
    if helper_total.positive?
      Rails.logger.info "[FulfillmentPreflight] ⚠️ ask_fills缺失，降级使用unfilled_amount: ask=#{ask_hash}, total=#{helper_total}"
      return helper_total
    end

    raise ValidationError, "missing ask expected total for strict full-fill: #{ask_hash}"
  end

  def assert_close!(left, right, message)
    return if (left - right).abs <= EPSILON

    raise ValidationError, message
  end

  def to_f(value)
    value.to_f
  end
end
