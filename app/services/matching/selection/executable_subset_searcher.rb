# frozen_string_literal: true

require 'set'

class Matching::Selection::ExecutableSubsetSearcher
  DEFAULT_OPTIONS = {
    max_layers: 5,
    max_targets: 8,
    flow_budget: 20,
    round_timeout_ms: 500,
    epsilon: 1e-9,
    max_bitset_size: 10_000
  }.freeze

  def initialize(bids:, asks:, options: {})
    @options = DEFAULT_OPTIONS.merge(options || {})
    @bids = normalize_orders(bids, side: :bid)
    @asks = normalize_orders(asks, side: :ask)
  end

  def call
    return empty_result('empty_pool') if @bids.empty? || @asks.empty?

    sorted_bids = @bids.sort_by { |bid| [-bid[:price], bid[:created_at]] }
    sorted_asks = @asks.sort_by { |ask| [ask[:price], ask[:created_at]] }
    edges = build_compatible_edges(sorted_bids, sorted_asks)
    return empty_result('no_compatible_edges') if edges.empty?

    layers = build_layers(edges)
    active_bid_idx = Set.new
    active_ask_idx = Set.new
    best = nil
    flow_attempts = 0
    deadline = monotonic_now + (@options[:round_timeout_ms].to_f / 1000.0)
    budget_exhausted = false
    timeout_hit = false

    layers.each_with_index do |layer, layer_idx|
      layer.each do |edge|
        active_bid_idx.add(edge[:bid_idx])
        active_ask_idx.add(edge[:ask_idx])
      end

      bid_sum_set = build_reachable_set(active_bid_idx.map { |idx| sorted_bids[idx][:qty] })
      ask_sum_set = build_reachable_set(active_ask_idx.map { |idx| sorted_asks[idx][:qty] })
      common_targets = intersect_targets(bid_sum_set, ask_sum_set)
      next if common_targets.empty?

      common_targets.first(@options[:max_targets]).each do |target_qty|
        if flow_attempts >= @options[:flow_budget]
          budget_exhausted = true
          break
        end

        if monotonic_now > deadline
          timeout_hit = true
          break
        end

        bid_subset_idx = exact_subset_indices(active_bid_idx.to_a, sorted_bids, target_qty)
        ask_subset_idx = exact_subset_indices(active_ask_idx.to_a, sorted_asks, target_qty)
        next if bid_subset_idx.nil? || ask_subset_idx.nil?

        flow_attempts += 1
        bid_subset = bid_subset_idx.map { |idx| sorted_bids[idx] }
        ask_subset = ask_subset_idx.map { |idx| sorted_asks[idx] }
        flow = solve_transport_flow(bid_subset, ask_subset)
        next unless flow[:feasible]

        candidate = {
          layer_index: layer_idx,
          target_qty: target_qty,
          bids: bid_subset,
          asks: ask_subset,
          flows: flow[:flows]
        }
        best = choose_better(best, candidate)
      end

      break if budget_exhausted || timeout_hit
    end

    return build_success_result(best, flow_attempts) if best
    return empty_result('flow_budget_exhausted', flow_attempts) if budget_exhausted
    return empty_result('round_timeout', flow_attempts) if timeout_hit

    empty_result('no_feasible_subset', flow_attempts)
  end

  private

  def normalize_orders(orders, side:)
    (orders || []).filter_map do |order|
      if order.is_a?(Hash)
        price = order[:price] || order['price']
        qty = order[:qty] || order['qty']
        hash = order[:hash] || order['hash']
        created_at = order[:created_at] || order['created_at']
      else
        price, qty, hash, _identifier, created_at = order
      end

      qty_i = qty.to_i
      next if qty_i <= 0

      {
        side: side,
        price: price.to_f,
        qty: qty_i,
        hash: hash.to_s,
        created_at: created_at || Time.at(0)
      }
    end
  end

  def build_compatible_edges(bids, asks)
    epsilon = @options[:epsilon].to_f
    edges = []

    bids.each_with_index do |bid, bid_idx|
      asks.each_with_index do |ask, ask_idx|
        next unless bid[:price] + epsilon >= ask[:price]

        edges << {
          bid_idx: bid_idx,
          ask_idx: ask_idx,
          spread: bid[:price] - ask[:price],
          bid_time: bid[:created_at],
          ask_time: ask[:created_at]
        }
      end
    end

    edges.sort_by { |edge| [-edge[:spread], edge[:bid_time], edge[:ask_time]] }
  end

  def build_layers(edges)
    layer_count = [@options[:max_layers].to_i, 1].max
    layer_size = (edges.size.to_f / layer_count).ceil
    edges.each_slice(layer_size).to_a
  end

  def build_reachable_set(qtys)
    total = qtys.sum
    return Set.new if total <= 0

    limit = [total, @options[:max_bitset_size].to_i].min
    reachable = Array.new(limit + 1, false)
    reachable[0] = true

    qtys.each do |qty|
      next if qty <= 0 || qty > limit

      limit.downto(qty) do |current|
        reachable[current] = true if reachable[current - qty]
      end
    end

    set = Set.new
    reachable.each_with_index { |v, idx| set.add(idx) if v }
    set
  end

  def intersect_targets(bid_sum_set, ask_sum_set)
    (bid_sum_set & ask_sum_set).to_a.select { |qty| qty.positive? }.sort.reverse
  end

  def exact_subset_indices(candidate_indices, orders, target_qty)
    return [] if target_qty.zero?

    max = target_qty.to_i
    dp = Array.new(max + 1, false)
    parent = Array.new(max + 1)
    dp[0] = true

    candidate_indices.each do |idx|
      qty = orders[idx][:qty]
      next if qty <= 0 || qty > max

      max.downto(qty) do |sum|
        next unless dp[sum - qty]
        next if dp[sum]

        dp[sum] = true
        parent[sum] = { prev: sum - qty, idx: idx }
      end
    end

    return nil unless dp[max]

    picked = []
    current = max
    while current.positive?
      node = parent[current]
      return nil if node.nil?

      picked << node[:idx]
      current = node[:prev]
    end
    picked
  end

  def solve_transport_flow(bids, asks)
    bid_count = bids.size
    ask_count = asks.size
    source = 0
    bid_offset = 1
    ask_offset = bid_offset + bid_count
    sink = ask_offset + ask_count
    node_count = sink + 1

    capacity = Array.new(node_count) { Array.new(node_count, 0.0) }
    flow = Array.new(node_count) { Array.new(node_count, 0.0) }
    adjacency = Array.new(node_count) { [] }

    add_edge = lambda do |from, to, cap|
      return if cap <= 0

      adjacency[from] << to unless adjacency[from].include?(to)
      adjacency[to] << from unless adjacency[to].include?(from)
      capacity[from][to] = cap.to_f
    end

    bids.each_with_index { |bid, idx| add_edge.call(source, bid_offset + idx, bid[:qty]) }
    asks.each_with_index { |ask, idx| add_edge.call(ask_offset + idx, sink, ask[:qty]) }

    epsilon = @options[:epsilon].to_f
    bids.each_with_index do |bid, bid_idx|
      asks.each_with_index do |ask, ask_idx|
        next unless bid[:price] + epsilon >= ask[:price]

        add_edge.call(bid_offset + bid_idx, ask_offset + ask_idx, ask[:qty])
      end
    end

    max_flow = 0.0
    loop do
      parent = Array.new(node_count, -1)
      parent[source] = source
      queue = [source]

      until queue.empty? || parent[sink] != -1
        node = queue.shift
        adjacency[node].each do |next_node|
          next unless parent[next_node] == -1

          residual = capacity[node][next_node] - flow[node][next_node]
          next unless residual > 1e-9

          parent[next_node] = node
          queue << next_node
        end
      end

      break if parent[sink] == -1

      increment = Float::INFINITY
      node = sink
      while node != source
        prev = parent[node]
        residual = capacity[prev][node] - flow[prev][node]
        increment = [increment, residual].min
        node = prev
      end

      node = sink
      while node != source
        prev = parent[node]
        flow[prev][node] += increment
        flow[node][prev] -= increment
        node = prev
      end

      max_flow += increment
    end

    required = bids.sum { |bid| bid[:qty] }.to_f
    return { feasible: false, flows: [] } if (max_flow - required).abs > 1e-6

    flows = []
    bids.each_with_index do |bid, bid_idx|
      asks.each_with_index do |ask, ask_idx|
        value = flow[bid_offset + bid_idx][ask_offset + ask_idx]
        next unless value > 1e-9

        flows << {
          bid_hash: bid[:hash],
          ask_hash: ask[:hash],
          qty: value
        }
      end
    end

    { feasible: true, flows: flows }
  end

  def choose_better(current, candidate)
    return candidate if current.nil?

    current_rank = [current[:layer_index], -current[:target_qty], aggregate_time_rank(current)]
    candidate_rank = [candidate[:layer_index], -candidate[:target_qty], aggregate_time_rank(candidate)]
    comparison = (candidate_rank <=> current_rank)
    comparison == -1 ? candidate : current
  end

  def aggregate_time_rank(candidate)
    bid_score = candidate[:bids].sum { |order| order[:created_at].to_f }
    ask_score = candidate[:asks].sum { |order| order[:created_at].to_f }
    bid_score + ask_score
  end

  def build_success_result(best, flow_attempts)
    {
      feasible: true,
      target_qty: best[:target_qty],
      layer_index: best[:layer_index],
      selected_bid_hashes: best[:bids].map { |bid| bid[:hash] },
      selected_ask_hashes: best[:asks].map { |ask| ask[:hash] },
      flows: best[:flows],
      flow_attempts: flow_attempts,
      exit_reason: 'matched'
    }
  end

  def empty_result(reason, flow_attempts = 0)
    {
      feasible: false,
      target_qty: 0,
      layer_index: nil,
      selected_bid_hashes: [],
      selected_ask_hashes: [],
      flows: [],
      flow_attempts: flow_attempts,
      exit_reason: reason
    }
  end

  def monotonic_now
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end
end
