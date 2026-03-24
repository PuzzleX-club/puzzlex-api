# frozen_string_literal: true

class Matching::Discovery::OrderDiscovery
  def initialize(market_id:, validator:, collection_support:, waiting_handler:, match_executor:)
    @market_id = market_id
    @validator = validator
    @collection_support = collection_support
    @waiting_handler = waiting_handler
    @match_executor = match_executor
  end

  def find_match_orders
    matched_orders = []
    Rails.logger.info "[MatchEngine] 🚀 开始撮合 - 市场: #{@market_id}"

    order_book = MarketData::OrderBookDepth.new(@market_id, 50).call
    Rails.logger.info "[MatchEngine] 📊 获取订单深度 - Bids: #{order_book[:bids]&.size || 0}, Asks: #{order_book[:asks]&.size || 0}"

    bids = order_book[:bids]
    asks = order_book[:asks]

    if order_book[:bids].empty? && order_book[:asks].empty?
      Rails.logger.warn "[MatchEngine] ⚠️ OrderBookDepth返回空数据 - 市场: #{@market_id}"
    end

    if order_book[:bids].nil? || order_book[:bids].empty? || order_book[:asks].nil? || order_book[:asks].empty?
      Rails.logger.debug "[MatchEngine] 无有效订单可撮合：bids=#{bids&.size || 0}, asks=#{asks&.size || 0}"
      set_waiting
      return []
    end

    validated_bids, validated_asks = validate_orders(bids, asks)
    if validated_bids.empty? || validated_asks.empty?
      Rails.logger.debug "[MatchEngine] 验证后无有效订单：validated_bids=#{validated_bids.size}, validated_asks=#{validated_asks.size}"
      set_waiting
      return []
    end

    @collection_support.preload_merkle_cache(validated_bids, validated_asks)
    compatible_groups = @collection_support.group_orders_by_compatibility(validated_bids, validated_asks)
    Rails.logger.info "[MatchEngine] 🔗 兼容性分组完成 - 组数: #{compatible_groups.size}"

    if compatible_groups.empty?
      Rails.logger.debug "[MatchEngine] 没有找到兼容的订单组"
      set_waiting
      return []
    end

    consumed_bid_hashes = {}
    consumed_ask_hashes = {}

    compatible_groups.each do |group|
      process_group(
        group: group,
        consumed_bid_hashes: consumed_bid_hashes,
        consumed_ask_hashes: consumed_ask_hashes,
        matched_orders: matched_orders
      )
    end

    if matched_orders.empty?
      Rails.logger.debug "[MatchEngine] 所有兼容组匹配完成后无结果"
      set_waiting
      return []
    end

    Rails.logger.info "[MatchEngine] ✅ 撮合成功 - 市场: #{@market_id}, 匹配数: #{matched_orders.size}"
    matched_orders
  end

  private

  def validate_orders(bids, asks)
    validation_result = @validator.filter_valid_orders_for_matching(bids, asks)
    validated_bids = validation_result[:bids].uniq { |bid| bid[2].to_s }
    validated_asks = validation_result[:asks].uniq { |ask| ask[2].to_s }
    [validated_bids, validated_asks]
  end

  def process_group(group:, consumed_bid_hashes:, consumed_ask_hashes:, matched_orders:)
    group_bids = group[:bids].reject { |bid| consumed_bid_hashes[bid[2].to_s] }
    group_asks = group[:asks].reject { |ask| consumed_ask_hashes[ask[2].to_s] }
    group_type = group[:type]

    Rails.logger.info "[MatchEngine] 开始处理#{group_type}组: #{group_bids.size}个买单, #{group_asks.size}个卖单"
    if group_bids.empty? || group_asks.empty?
      Rails.logger.debug "[MatchEngine] 跳过#{group_type}组：去重后无可用订单"
      return
    end

    sorted_bids = group_bids.sort_by { |bid| -bid[0].to_f }
    sorted_asks = group_asks.sort_by { |ask| ask[0].to_f }

    max_bid_price = sorted_bids.first[0].to_f
    min_ask_price = sorted_asks.first[0].to_f

    Rails.logger.info "[MatchEngine] 价格范围: 最高买价=#{max_bid_price}, 最低卖价=#{min_ask_price}"

    filtered_bids = sorted_bids.select { |bid| bid[0].to_f >= min_ask_price }
    filtered_asks = sorted_asks.select { |ask| ask[0].to_f <= max_bid_price }

    Rails.logger.info "[MatchEngine] 筛选后: #{filtered_bids.size}个买单, #{filtered_asks.size}个卖单"
    return if filtered_bids.empty? || filtered_asks.empty?

    Rails.logger.info "[MatchEngine] 处理#{group_type}匹配组：#{filtered_bids.size}个买单，#{filtered_asks.size}个卖单"

    group_matches = @match_executor.call(filtered_bids, filtered_asks)
    return unless group_matches.present?

    group_matches.each do |match|
      next unless match['side'] == 'Offer'

      bid_hash = match.dig('bid', 2).to_s
      consumed_bid_hashes[bid_hash] = true if bid_hash.present?

      Array(match.dig('ask', :current_orders)).each do |ask_hash|
        consumed_ask_hashes[ask_hash.to_s] = true if ask_hash.present?
      end
    end

    matched_orders.concat(group_matches)
    Rails.logger.info "[MatchEngine] #{group_type}组产生 #{group_matches.size} 个匹配"
  end

  def set_waiting
    @waiting_handler.call
  end
end
