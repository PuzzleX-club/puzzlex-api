# frozen_string_literal: true

# Seaport `matchOrders` 在单次调用中要求 fulfillment 被完整满足，
# 因此撮合阶段必须只产出“完全撮合（exact full fill）”方案。
# 本求解器只做精确解搜索：有解返回 full-fill 组合，无解返回空组合。
class Matching::Selection::ExactFillSolver
  def initialize(target_qty:, asks:, scale_factor: 1)
    @target_qty = target_qty.to_f
    @asks = asks || []
    @scale_factor = scale_factor.to_i <= 0 ? 1 : scale_factor.to_i
  end

  def solve
    # 严格语义：不允许返回 partial 方案，目标是精确命中 target_qty。
    return no_match(@target_qty) if @asks.empty?
    return exact_match([], 0, 0) if @target_qty.zero?

    scaled_target = scale(@target_qty)
    return no_match(@target_qty) if scaled_target.negative?

    scaled_asks = normalize_asks
    total_scaled_qty = scaled_asks.sum { |ask| ask[:qty_scaled] > 0 ? ask[:qty_scaled] : 0 }
    return no_match(@target_qty) if scaled_target > total_scaled_qty

    dp = Array.new(scaled_target + 1, false)
    parent = Array.new(scaled_target + 1)
    dp[0] = true

    scaled_asks.each_with_index do |ask, ask_idx|
      qty_scaled = ask[:qty_scaled]
      next if qty_scaled <= 0 || qty_scaled > scaled_target

      scaled_target.downto(qty_scaled) do |current|
        next unless dp[current - qty_scaled]
        next if dp[current]

        dp[current] = true
        parent[current] = parent[current - qty_scaled].to_a + [ask_idx]
      end
    end

    return no_match(@target_qty) unless dp[scaled_target]

    picked_indices = parent[scaled_target].to_a
    picked_orders = picked_indices.map { |idx| scaled_asks[idx][:order_hash] }
    picked_scaled_qty = picked_indices.sum { |idx| scaled_asks[idx][:qty_scaled] }
    matched_qty = unscale(picked_scaled_qty)

    exact_match(picked_orders, matched_qty, @target_qty - matched_qty)
  end

  private

  def normalize_asks
    @asks.map do |ask|
      price, qty_raw, order_hash, identifier, created_at = ask
      qty_float = qty_raw.to_f
      {
        price: price,
        qty_scaled: scale(qty_float),
        qty: qty_float,
        order_hash: order_hash,
        identifier: identifier,
        created_at: created_at
      }
    end
  end

  def scale(qty)
    (qty.to_f * @scale_factor).round
  end

  def unscale(scaled_qty)
    scaled_qty.to_f / @scale_factor
  end

  def no_match(remaining_qty)
    {
      current_orders: [],
      match_completed: false,
      remaining_qty: remaining_qty,
      matched_qty: 0
    }
  end

  def exact_match(orders, matched_qty, remaining_qty)
    {
      current_orders: orders,
      match_completed: true,
      remaining_qty: remaining_qty,
      matched_qty: matched_qty
    }
  end
end
