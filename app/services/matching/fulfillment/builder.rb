# frozen_string_literal: true

class Matching::Fulfillment::Builder
  def initialize(market_id:, collection_support:)
    @market_id = market_id
    @collection_support = collection_support
  end

  def generate(match_orders, mxn_enabled:)
    return generate_v2(match_orders) if mxn_enabled

    generate_legacy(match_orders)
  end

  def generate_v2(match_orders)
    all_order_hashes = []
    match_orders.each do |match|
      next unless match['side'] == 'Offer'

      all_order_hashes << match.dig('bid', 2)
      all_order_hashes.concat(match.dig('ask', :current_orders) || [])
    end

    orders_by_hash = load_orders_by_hash(all_order_hashes)

    graph = Matching::Fulfillment::GraphBuilder.new(
      match_orders: match_orders,
      orders_by_hash: orders_by_hash
    ).build

    Matching::Fulfillment::PreflightValidator.new(
      match_orders: match_orders,
      graph: graph,
      orders_by_hash: orders_by_hash
    ).validate!

    criteria_resolvers = @collection_support.build_criteria_resolvers_from_graph(
      match_orders,
      graph,
      orders_by_hash
    )

    result = {
      market_id: @market_id,
      match_data_version: 'v2',
      orders: graph[:orders],
      fulfillments: graph[:fulfillments],
      orders_hash: graph[:orders_hash],
      fills: graph[:fills]
    }

    if criteria_resolvers.any?
      result[:criteriaResolvers] = criteria_resolvers
      Rails.logger.info "[MatchEngine] 📦 v2 criteriaResolvers: #{criteria_resolvers.size} 个"
    end

    Rails.logger.info "[MatchEngine] ✅ v2 fulfillment graph + preflight 通过: orders=#{result[:orders].size}, fulfillments=#{result[:fulfillments].size}, fills=#{result[:fills].size}"
    result
  rescue Matching::Fulfillment::PreflightValidator::ValidationError => e
    Rails.logger.error "[MatchEngine] ❌ v2 preflight失败: #{e.message}"
    raise
  end

  private

  def generate_legacy(match_orders)
    orders_data = []
    orders_hash = []
    fulfillments_data = []
    criteria_resolvers = []

    all_order_hashes = []
    match_orders.each do |match|
      next unless match['side'] == 'Offer'

      all_order_hashes << match['bid'][2]
      all_order_hashes.concat(match['ask'][:current_orders])
    end

    orders_by_hash = load_orders_by_hash(all_order_hashes)

    match_orders.each do |match|
      next unless match['side'] == 'Offer'

      bid_order = orders_by_hash[match['bid'][2]]
      ask_orders = Array(match['ask'][:current_orders]).map { |order_hash| orders_by_hash[order_hash] }.compact

      if bid_order.nil?
        Rails.logger.error "[MATCHING_ERROR] 买单未找到: #{match['bid'][2]}"
        next
      end

      if ask_orders.empty?
        Rails.logger.error "[MATCHING_ERROR] 卖单未找到: #{match['ask'][:current_orders]}"
        next
      end

      Rails.logger.debug "[BATCH_QUERY_OPTIMIZED] 批量查询了 #{all_order_hashes.uniq.size} 个订单，当前匹配组: 1买单 + #{ask_orders.size}卖单"

      start_index = orders_data.size
      orders_data << {
        parameters: bid_order.parameters,
        signature: bid_order.signature
      }
      orders_hash << bid_order.order_hash

      build_collection_criteria_resolvers!(
        criteria_resolvers: criteria_resolvers,
        bid_order: bid_order,
        ask_orders: ask_orders,
        buyer_order_index: start_index
      )

      ask_orders.each do |ask_order|
        orders_data << {
          parameters: ask_order.parameters,
          signature: ask_order.signature
        }
        orders_hash << ask_order.order_hash
      end

      append_legacy_fulfillments!(
        fulfillments_data: fulfillments_data,
        buyer_index: start_index,
        ask_count: ask_orders.size
      )
    end

    build_legacy_result(
      orders_data: orders_data,
      fulfillments_data: fulfillments_data,
      orders_hash: orders_hash,
      criteria_resolvers: criteria_resolvers
    )
  end

  def load_orders_by_hash(order_hashes)
    return {} if order_hashes.blank?

    Trading::Order.where(order_hash: order_hashes.uniq).index_by(&:order_hash)
  end

  def build_collection_criteria_resolvers!(criteria_resolvers:, bid_order:, ask_orders:, buyer_order_index:)
    is_collection_bid = bid_order.order_direction == 'Offer' &&
      @collection_support.is_collection_order?(bid_order.consideration_identifier)

    Rails.logger.info "[MatchEngine] 检查Collection订单:"
    Rails.logger.info "[MatchEngine]   bid_order.order_direction: #{bid_order.order_direction}"
    Rails.logger.info "[MatchEngine]   bid_order.consideration_identifier: #{bid_order.consideration_identifier}"
    Rails.logger.info "[MatchEngine]   is_collection_order: #{@collection_support.is_collection_order?(bid_order.consideration_identifier)}"
    Rails.logger.info "[MatchEngine]   is_collection_bid: #{is_collection_bid}"

    unless is_collection_bid
      Rails.logger.info "[MatchEngine] ⚠️ 不是Collection买单，不需要生成criteriaResolvers"
      return
    end

    Rails.logger.info "[MatchEngine] ✅ 检测到Collection买单，需要生成criteriaResolvers"
    Rails.logger.info "[MatchEngine]   MerkleRoot: #{bid_order.consideration_identifier}"

    ask_orders.each do |ask_order|
      Rails.logger.info "[MatchEngine] 为卖单 #{ask_order.order_hash[0..10]}... 生成criteriaResolver"

      criteria_resolver = @collection_support.generate_criteria_resolver_for_order(
        buyer_order_index,
        ask_order,
        bid_order.consideration_identifier
      )

      if criteria_resolver
        criteria_resolvers << criteria_resolver
        Rails.logger.info "[MatchEngine] ✅ 成功生成criteriaResolver: orderIndex=#{criteria_resolver[:orderIndex]}, tokenId=#{criteria_resolver[:identifier]}"
      else
        Rails.logger.warn "[MatchEngine] ❌ 无法为订单生成criteriaResolver: #{ask_order.order_hash}"
      end
    end

    Rails.logger.info "[MatchEngine] 共生成 #{criteria_resolvers.size} 个criteriaResolvers"
  end

  def append_legacy_fulfillments!(fulfillments_data:, buyer_index:, ask_count:)
    ask_count.times do |index|
      seller_index = buyer_index + 1 + index

      fulfillments_data << {
        offerComponents: [{ orderIndex: buyer_index, itemIndex: 0 }],
        considerationComponents: [{ orderIndex: seller_index, itemIndex: 0 }]
      }
      fulfillments_data << {
        offerComponents: [{ orderIndex: buyer_index, itemIndex: 1 }],
        considerationComponents: [{ orderIndex: seller_index, itemIndex: 1 }]
      }
      fulfillments_data << {
        offerComponents: [{ orderIndex: buyer_index, itemIndex: 2 }],
        considerationComponents: [{ orderIndex: seller_index, itemIndex: 2 }]
      }
      fulfillments_data << {
        offerComponents: [{ orderIndex: seller_index, itemIndex: 0 }],
        considerationComponents: [{ orderIndex: buyer_index, itemIndex: 0 }]
      }
    end
  end

  def build_legacy_result(orders_data:, fulfillments_data:, orders_hash:, criteria_resolvers:)
    result = {
      market_id: @market_id,
      orders: orders_data,
      fulfillments: fulfillments_data,
      orders_hash: orders_hash
    }

    if criteria_resolvers.any?
      result[:criteriaResolvers] = criteria_resolvers
      Rails.logger.info "[MatchEngine] ========== 撮合结果包含criteriaResolvers =========="
      Rails.logger.info "[MatchEngine] 添加#{criteria_resolvers.size}个criteriaResolvers到结果"
      criteria_resolvers.each_with_index do |cr, index|
        Rails.logger.info "[MatchEngine] CriteriaResolver #{index + 1}:"
        Rails.logger.info "[MatchEngine]   orderIndex: #{cr[:orderIndex]}"
        Rails.logger.info "[MatchEngine]   side: #{cr[:side]}"
        Rails.logger.info "[MatchEngine]   index: #{cr[:index]}"
        Rails.logger.info "[MatchEngine]   identifier: #{cr[:identifier]}"
        Rails.logger.info "[MatchEngine]   criteriaProof: #{cr[:criteriaProof].first(3).inspect}..."
      end
      Rails.logger.info "[MatchEngine] ================================================"
    else
      Rails.logger.info "[MatchEngine] ⚠️ 没有criteriaResolvers在撮合结果中"
    end

    result
  end
end
