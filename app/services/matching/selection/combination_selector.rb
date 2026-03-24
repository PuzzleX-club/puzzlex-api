# frozen_string_literal: true

class Matching::Selection::CombinationSelector
  def initialize(scale_factor:, max_dp_array_size:, max_recursion_depth:)
    @scale_factor = scale_factor
    @max_dp_array_size = max_dp_array_size
    @max_recursion_depth = max_recursion_depth
  end

  def should_use_greedy_algorithm(bid_order, _target_qty, _available_asks)
    return false unless bid_order

    if bid_order.allows_partial_fill?
      Rails.logger.info "[MATCH_STRATEGY] 订单 #{bid_order.order_hash[0..7]}... 允许部分成交，使用贪心算法"
      return true
    end

    if bid_order.requires_full_fill?
      Rails.logger.info "[MATCH_STRATEGY] 订单 #{bid_order.order_hash[0..7]}... 必须全部成交，使用DP算法"
      return false
    end

    false
  end

  def find_optimal_combination_greedy(target_qty, asks)
    return { current_orders: [], match_completed: false, remaining_qty: target_qty } if asks.empty?
    return { current_orders: [], match_completed: true, remaining_qty: 0 } if target_qty == 0

    Rails.logger.info "[GREEDY_MATCHING] 🎯 贪心匹配，目标数量: #{target_qty}, 可选卖单: #{asks.length}个"

    matched_orders = []
    matched_qty = 0
    remaining_qty = target_qty

    sorted_asks = asks.sort_by { |price, _qty, _hash, _identifier, created_at| [price, created_at] }

    sorted_asks.each do |_price, qty, hash, _identifier, _created_at|
      qty_num = qty.to_f

      if qty_num <= remaining_qty
        matched_orders << hash
        matched_qty += qty_num
        remaining_qty -= qty_num
        Rails.logger.debug "[GREEDY_MATCHING] 完全匹配卖单 #{hash[0..7]}...: #{qty_num}个"

        if remaining_qty == 0
          Rails.logger.info "[GREEDY_MATCHING] 🎉 完全匹配成功！总计匹配: #{matched_qty}个"
          return {
            current_orders: matched_orders,
            match_completed: true,
            remaining_qty: 0,
            matched_qty: matched_qty
          }
        end
      elsif remaining_qty > 0
        matched_orders << hash
        matched_qty += remaining_qty
        Rails.logger.debug "[GREEDY_MATCHING] 部分匹配卖单 #{hash[0..7]}...: 使用 #{remaining_qty}/#{qty_num}个"
        remaining_qty = 0

        Rails.logger.info "[GREEDY_MATCHING] 🎯 部分匹配完成！总计匹配: #{matched_qty}个"
        return {
          current_orders: matched_orders,
          match_completed: false,
          remaining_qty: 0,
          matched_qty: matched_qty,
          partial_match: true
        }
      end
    end

    if matched_qty > 0
      Rails.logger.info "[GREEDY_MATCHING] ⚠️ 卖单不足，部分匹配: #{matched_qty}/#{target_qty}个"
      {
        current_orders: matched_orders,
        match_completed: false,
        remaining_qty: remaining_qty,
        matched_qty: matched_qty,
        partial_match: true
      }
    else
      Rails.logger.warn "[GREEDY_MATCHING] ❌ 无法匹配任何订单"
      {
        current_orders: [],
        match_completed: false,
        remaining_qty: target_qty,
        matched_qty: 0
      }
    end
  end

  def find_optimal_combination_dp(target_qty, asks, legacy_fallback:, algorithm_fallback_logger:)
    return { current_orders: [], match_completed: false, remaining_qty: target_qty } if asks.empty?
    return { current_orders: [], match_completed: true, remaining_qty: 0 } if target_qty == 0

    target_qty_float = target_qty.to_f
    scaled_target = (target_qty_float * @scale_factor).round
    asks_for_calc = asks.map do |price, qty_str, hash, identifier, created_at|
      [price, qty_str.to_f, hash, identifier, created_at]
    end

    total_ask_qty_scaled = asks_for_calc.sum do |_, qty_float, _, _, _|
      qty_scaled = (qty_float * @scale_factor).round
      qty_scaled.positive? ? qty_scaled : 0
    end
    if scaled_target > total_ask_qty_scaled
      total_ask_qty_original = (total_ask_qty_scaled.to_f / @scale_factor).round(2)
      Rails.logger.warn "[DP_MATCHING] ⚠️ 买单数量 #{target_qty_float} 超过有效卖单总量 #{total_ask_qty_original}，严格模式返回无匹配"
      return { current_orders: [], match_completed: false, remaining_qty: target_qty, matched_qty: 0 }
    end

    if scaled_target > @max_dp_array_size * @scale_factor
      algorithm_fallback_logger.call('dp', 'recursive', "目标数量 #{target_qty_float} 超过DP算法安全限制")
      Rails.logger.warn "[DP_MATCHING] ⚠️ 目标数量 #{target_qty_float} 超过DP算法安全限制，降级使用递归算法"
      return legacy_fallback.call(target_qty, asks, 0, [], 0)
    end

    estimated_memory_mb = (scaled_target * 2 * 8) / 1024.0 / 1024.0
    if estimated_memory_mb > 100
      algorithm_fallback_logger.call('dp', 'recursive', "预估内存使用 #{estimated_memory_mb.round(2)}MB 过大")
      Rails.logger.warn "[DP_MATCHING] ⚠️ 预估内存使用 #{estimated_memory_mb.round(2)}MB 过大，降级使用递归算法"
      return legacy_fallback.call(target_qty, asks, 0, [], 0)
    end

    Rails.logger.info "[DP_MATCHING] 🎯 目标数量: #{target_qty_float} (缩放后: #{scaled_target}), 可选卖单: #{asks_for_calc.length}个, 预估内存: #{estimated_memory_mb.round(2)}MB"

    solver_result = Matching::Selection::ExactFillSolver.new(
      target_qty: target_qty_float,
      asks: asks_for_calc,
      scale_factor: @scale_factor
    ).solve

    if solver_result[:match_completed]
      selected_qtys_original = asks_for_calc.select do |_, _, hash, _, _|
        solver_result[:current_orders].include?(hash)
      end.map { |_, qty_float, _, _, _| qty_float }
      Rails.logger.info "[DP_MATCHING] 🎉 找到完全匹配方案！选择订单: #{selected_qtys_original} (总和=#{selected_qtys_original.sum.round(2)})"
      solver_result
    else
      Rails.logger.info "[DP_MATCHING] ❌ 无法找到完全匹配方案（目标: #{target_qty_float}）"
      solver_result
    end
  rescue => e
    algorithm_fallback_logger.call('dp', 'recursive', "动态规划算法异常: #{e.message}")
    Rails.logger.error "[DP_MATCHING] ❌ 动态规划算法出错: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")
    Rails.logger.warn "[DP_MATCHING] 🔄 降级使用递归算法"
    legacy_fallback.call(target_qty, asks, 0, [], 0)
  end

  def find_best_ask_combination(_bids, asks, start_idx:, current_combination:, dp_solver:)
    target_qty = current_combination[:remaining_qty]
    available_asks = asks[start_idx..-1]

    Rails.logger.info "[MATCH_STRATEGY] 🚀 使用动态规划算法匹配（严格全量撮合），目标数量: #{target_qty}, 可用卖单: #{available_asks.length}个"
    result = dp_solver.call(target_qty, available_asks)

    if result[:match_completed]
      {
        current_qty: target_qty,
        match_completed: true,
        remaining_qty: 0,
        current_orders: result[:current_orders]
      }
    else
      {
        current_qty: current_combination[:current_qty],
        match_completed: false,
        remaining_qty: target_qty,
        current_orders: []
      }
    end
  end

  def find_best_ask_combination_legacy(target_qty, asks, start_idx:, current_orders:, depth:)
    if depth > @max_recursion_depth
      Rails.logger.warn "[LEGACY_MATCHING] ⚠️ 递归深度 #{depth} 超过安全限制，终止递归"
      return { match_completed: false, current_orders: [] }
    end

    if target_qty > 1000 && depth.zero?
      Rails.logger.info "[LEGACY_MATCHING] 🔄 处理大订单 #{target_qty}，使用优化递归算法"
    end

    Rails.logger.debug "[LEGACY_MATCHING] 递归匹配，目标: #{target_qty}, 起始索引: #{start_idx}, 深度: #{depth}"

    return { match_completed: true, current_orders: current_orders } if target_qty == 0
    return { match_completed: false, current_orders: [] } if start_idx >= asks.length
    return { match_completed: false, current_orders: [] } if target_qty < 0

    remaining_asks = asks[start_idx..-1]
    remaining_total = remaining_asks.sum { |_, qty, _, _| qty }
    if remaining_total < target_qty
      Rails.logger.info "[LEGACY_MATCHING] 剩余卖单总量 #{remaining_total} < 目标 #{target_qty}，严格模式返回无匹配"
      return { match_completed: false, current_orders: [] }
    end

    min_remaining = remaining_asks.map { |_, qty, _, _| qty }.min
    return { match_completed: false, current_orders: [] } if min_remaining > target_qty

    exact_match = remaining_asks.find { |_, qty, _, _| qty == target_qty }
    if exact_match
      Rails.logger.info "[LEGACY_MATCHING] 🎯 找到精确匹配: #{exact_match[2][0..7]}..."
      return { match_completed: true, current_orders: current_orders + [exact_match[2]] }
    end

    _price, qty, hash, _created_at = asks[start_idx]
    if qty <= target_qty
      with_current = find_best_ask_combination_legacy(
        target_qty - qty,
        asks,
        start_idx: start_idx + 1,
        current_orders: current_orders + [hash],
        depth: depth + 1
      )
      return with_current if with_current[:match_completed]
    end

    find_best_ask_combination_legacy(
      target_qty,
      asks,
      start_idx: start_idx + 1,
      current_orders: current_orders,
      depth: depth + 1
    )
  end
end
