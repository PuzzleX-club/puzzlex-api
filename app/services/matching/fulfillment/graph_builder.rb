class Matching::Fulfillment::GraphBuilder
  def initialize(match_orders:, orders_by_hash:)
    @match_orders = match_orders || []
    @orders_by_hash = orders_by_hash || {}
  end

  def build
    orders_data = []
    orders_hash = []
    fulfillments_data = []
    fills_data = []
    order_index_map = {}
    group_contexts = []
    ask_to_bid_edges = Hash.new { |memo, key| memo[key] = {} }

    # 全局去重收集订单，支持同一 ask 在多个 bid 中被拆分成交。
    unique_hashes = []
    @match_orders.each do |match|
      next unless match['side'] == 'Offer'

      bid_hash = match.dig('bid', 2).to_s
      ask_hashes = (match.dig('ask', :current_orders) || []).map(&:to_s)
      unique_hashes << bid_hash if bid_hash.present?
      ask_hashes.each { |ask_hash| unique_hashes << ask_hash if ask_hash.present? }
    end

    unique_hashes.uniq.each do |order_hash|
      order = @orders_by_hash[order_hash]
      next if order.nil?

      order_index_map[order_hash] = orders_data.size
      orders_data << {
        parameters: order.parameters,
        signature: order.signature
      }
      orders_hash << order_hash
    end

    @match_orders.each do |match|
      next unless match['side'] == 'Offer'

      bid_hash = match.dig('bid', 2)
      ask_hashes = (match.dig('ask', :current_orders) || []).map(&:to_s)
      bid_order = @orders_by_hash[bid_hash]
      ask_orders = ask_hashes.map { |order_hash| @orders_by_hash[order_hash] }.compact

      next if bid_order.nil? || ask_orders.empty?
      buyer_index = order_index_map[bid_order.order_hash.to_s]
      next if buyer_index.nil?

      ask_fill_lookup = Array(match['ask_fills']).each_with_object({}) do |fill, memo|
        next unless fill.is_a?(Hash)
        ask_hash = fill['order_hash'].to_s
        filled_qty = fill['filled_qty'].to_f
        next if ask_hash.empty? || filled_qty <= 0
        memo[ask_hash] = filled_qty
      end

      ask_orders.each do |ask_order|
        seller_index = order_index_map[ask_order.order_hash.to_s]
        next if seller_index.nil?

        filled_qty = ask_fill_lookup[ask_order.order_hash.to_s]
        if filled_qty.nil? || filled_qty <= 0
          filled_qty = Orders::OrderHelper.calculate_unfill_amount_from_order(ask_order).to_f
          if filled_qty.positive?
            Rails.logger.info "[FulfillmentGraphBuilder] ⚠️ ask_fills缺失，降级使用unfilled_amount: ask=#{ask_order.order_hash}, filled_qty=#{filled_qty}"
          end
        end
        next if filled_qty <= 0

        ask_to_bid_edges[ask_order.order_hash.to_s][bid_order.order_hash.to_s] ||= 0.0
        ask_to_bid_edges[ask_order.order_hash.to_s][bid_order.order_hash.to_s] += filled_qty

        fills_data << {
          bid_hash: bid_order.order_hash,
          ask_hash: ask_order.order_hash,
          bid_order_index: buyer_index,
          ask_order_index: seller_index,
          filled_qty: filled_qty,
          partial_match: match['partial_match'] || false
        }
      end

      group_contexts << {
        bid_hash: bid_order.order_hash.to_s,
        ask_hashes: ask_orders.map { |order| order.order_hash.to_s },
        bid_order_index: buyer_index
      }
    end

    # 基于 fills 聚合构建 fulfillments，避免同一 ask 在 MxN 场景中被 pair 级重复消费。
    ask_to_bid_edges.each do |ask_hash, bid_qty_map|
      seller_index = order_index_map[ask_hash]
      next if seller_index.nil?
      ask_order = @orders_by_hash[ask_hash]
      next if ask_order.nil?

      bid_components = bid_qty_map.keys.filter_map do |bid_hash|
        buyer_index = order_index_map[bid_hash]
        next if buyer_index.nil?
        bid_order = @orders_by_hash[bid_hash]
        next if bid_order.nil?
        { orderIndex: buyer_index, order: bid_order }
      end
      next if bid_components.empty?

      ask_payment_item_indexes(ask_order).each do |item_index|
        ask_consideration_item = order_consideration_items(ask_order)[item_index]

        payment_groups = bid_components.each_with_object({}) do |component, memo|
          payment_item_index = payment_offer_item_index(component[:order], ask_consideration_item, item_index)
          key = payment_offer_group_key(component[:order], payment_item_index)
          memo[key] ||= []
          memo[key] << {
            orderIndex: component[:orderIndex],
            itemIndex: payment_item_index
          }
        end

        payment_groups.each_value do |offer_components|
          fulfillments_data << {
            offerComponents: offer_components,
            considerationComponents: [{ orderIndex: seller_index, itemIndex: item_index }]
          }
        end
      end

      ask_offer_nft_item_indexes(ask_order).each do |ask_offer_item_index|
        nft_consideration_groups = bid_components.each_with_object({}) do |component, memo|
          bid_nft_consideration_item_indexes(component[:order]).each do |consideration_item_index|
            key = bid_nft_consideration_group_key(component[:order], consideration_item_index)
            memo[key] ||= []
            memo[key] << {
              orderIndex: component[:orderIndex],
              itemIndex: consideration_item_index
            }
          end
        end

        nft_consideration_groups.each_value do |consideration_components|
          fulfillments_data << {
            offerComponents: [{ orderIndex: seller_index, itemIndex: ask_offer_item_index }],
            considerationComponents: consideration_components
          }
        end
      end
    end

    {
      orders: orders_data,
      fulfillments: fulfillments_data,
      orders_hash: orders_hash,
      fills: fills_data,
      order_index_map: order_index_map,
      groups: group_contexts
    }
  end

  private
  def order_offer_items(order)
    parameters = order.parameters || {}
    Array(parameters['offer'] || parameters[:offer])
  end

  def order_consideration_items(order)
    parameters = order.parameters || {}
    Array(parameters['consideration'] || parameters[:consideration])
  end

  def ask_payment_item_indexes(ask_order)
    indexes = order_consideration_items(ask_order).each_with_index.filter_map do |item, index|
      item_type = (item['itemType'] || item[:itemType]).to_i
      index if [0, 1].include?(item_type)
    end
    indexes.presence || [0]
  end

  def ask_offer_nft_item_indexes(ask_order)
    indexes = order_offer_items(ask_order).each_with_index.filter_map do |item, index|
      item_type = (item['itemType'] || item[:itemType]).to_i
      index if [2, 3, 4, 5].include?(item_type)
    end
    indexes.presence || [0]
  end

  def bid_nft_consideration_item_indexes(bid_order)
    indexes = order_consideration_items(bid_order).each_with_index.filter_map do |item, index|
      item_type = (item['itemType'] || item[:itemType]).to_i
      index if [2, 3, 4, 5].include?(item_type)
    end
    indexes.presence || [0]
  end

  def payment_offer_group_key(bid_order, item_index)
    offer_item = order_offer_items(bid_order)[item_index] || {}
    params = bid_order.parameters || {}
    offerer = (params['offerer'] || params[:offerer]).to_s.downcase
    conduit = (params['conduitKey'] || params[:conduitKey]).to_s.downcase
    item_type = (offer_item['itemType'] || offer_item[:itemType]).to_i
    token = (offer_item['token'] || offer_item[:token]).to_s.downcase
    identifier = (offer_item['identifierOrCriteria'] || offer_item[:identifierOrCriteria]).to_s

    [offerer, conduit, item_type, token, identifier]
  end

  def bid_nft_consideration_group_key(bid_order, item_index)
    consideration_item = order_consideration_items(bid_order)[item_index] || {}
    item_type = (consideration_item['itemType'] || consideration_item[:itemType]).to_i
    token = (consideration_item['token'] || consideration_item[:token]).to_s.downcase
    identifier = (consideration_item['identifierOrCriteria'] || consideration_item[:identifierOrCriteria]).to_s
    recipient = (consideration_item['recipient'] || consideration_item[:recipient]).to_s.downcase

    [item_type, token, identifier, recipient]
  end

  def payment_offer_item_index(bid_order, ask_consideration_item, preferred_index)
    offer_items = order_offer_items(bid_order)
    return 0 if offer_items.empty?
    return 0 if ask_consideration_item.nil?

    ask_item_type = (ask_consideration_item['itemType'] || ask_consideration_item[:itemType]).to_i
    ask_token = (ask_consideration_item['token'] || ask_consideration_item[:token]).to_s.downcase

    preferred_item = offer_items[preferred_index]
    if preferred_item
      preferred_item_type = (preferred_item['itemType'] || preferred_item[:itemType]).to_i
      preferred_token = (preferred_item['token'] || preferred_item[:token]).to_s.downcase
      if preferred_item_type == ask_item_type && (ask_item_type == 0 || preferred_token == ask_token)
        return preferred_index
      end
    end

    matched_index = offer_items.find_index do |item|
      offer_item_type = (item['itemType'] || item[:itemType]).to_i
      next false unless offer_item_type == ask_item_type
      next true if ask_item_type == 0

      offer_token = (item['token'] || item[:token]).to_s.downcase
      offer_token == ask_token
    end

    matched_index || 0
  end
end
