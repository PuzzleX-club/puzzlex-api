# frozen_string_literal: true

class Matching::Collection::OrderSupport
  def is_collection_order?(identifier)
    return false if identifier.nil? || identifier.empty?

    identifier.start_with?('0x') && identifier.length == 66
  end

  def token_in_merkle_tree?(token_id, merkle_root)
    return false if token_id.blank? || merkle_root.blank?

    root_record = Merkle::TreeRoot.find_latest_active_by_root_hash(merkle_root)
    unless root_record
      Rails.logger.warn "[MERKLE_CACHE] Merkle根已失效或不存在: #{merkle_root}"
      return false
    end

    cache_key = "merkle_verify:v2:#{merkle_root}:#{root_record.snapshot_id}:#{token_id}"
    cached_result = Rails.cache.read(cache_key)

    if cached_result.nil?
      Rails.logger.debug "[MERKLE_CACHE] 缓存未命中，查询数据库: #{cache_key}"

      result = verify_token_in_merkle_with_snapshot(token_id, root_record)
      cache_expiry = calculate_safe_cache_expiry(root_record, result)
      Rails.cache.write(cache_key, result, expires_in: cache_expiry)

      Rails.logger.debug "[MERKLE_CACHE] 缓存结果: #{cache_key} = #{result} (#{cache_expiry}s)"
      result
    else
      if root_record.expires_at && root_record.expires_at < Time.current
        Rails.logger.warn "[MERKLE_CACHE] 缓存命中但Merkle根已过期，清理缓存: #{merkle_root}"
        Rails.cache.delete(cache_key)
        return false
      end

      Rails.logger.debug "[MERKLE_CACHE] 缓存命中且有效: #{cache_key} = #{cached_result}"
      cached_result
    end
  rescue => e
    Rails.logger.error "[MatchEngine] 验证token_id #{token_id} 在Merkle树 #{merkle_root} 中时出错: #{e.message}"
    false
  end

  def verify_token_in_merkle_with_snapshot(token_id, root_record)
    Merkle::TreeNode.exists?(
      snapshot_id: root_record.snapshot_id,
      token_id: token_id.to_s,
      is_leaf: true
    )
  rescue => e
    Rails.logger.error "[MatchEngine] 验证token_id #{token_id} 在snapshot #{root_record.snapshot_id} 中时出错: #{e.message}"
    false
  end

  def calculate_safe_cache_expiry(root_record, verification_result)
    base_expiry = verification_result ? 300 : 60

    if root_record.expires_at
      remaining_time = (root_record.expires_at - Time.current).to_i

      if remaining_time <= 0
        return 0
      elsif remaining_time < base_expiry
        safe_expiry = (remaining_time * 0.8).to_i
        Rails.logger.debug "[MERKLE_CACHE] 缩短缓存时间至 #{safe_expiry}s (Merkle根剩余 #{remaining_time}s)"
        return [safe_expiry, 10].max
      end
    end

    base_expiry
  end

  def generate_criteria_resolver_for_order(order_index, ask_order, merkle_root)
    Rails.logger.info "[MatchEngine] ========== 开始生成criteriaResolver =========="
    Rails.logger.info "[MatchEngine] order_index: #{order_index}"
    Rails.logger.info "[MatchEngine] ask_order.order_hash: #{ask_order.order_hash}"
    Rails.logger.info "[MatchEngine] merkle_root: #{merkle_root}"

    token_id = ask_order.offer_identifier
    Rails.logger.info "[MatchEngine] token_id from offer_identifier: #{token_id}"

    if token_id.blank?
      Rails.logger.warn "[MatchEngine] 卖单缺少offer_identifier: #{ask_order.order_hash}"
      return nil
    end

    root_record = Merkle::TreeRoot.find_latest_active_by_root_hash(merkle_root)
    unless root_record
      Rails.logger.warn "[MatchEngine] 未找到Merkle根记录: #{merkle_root}"
      return nil
    end
    Rails.logger.info "[MatchEngine] 找到Merkle根记录: snapshot_id=#{root_record.snapshot_id}, item_id=#{root_record.item_id}"

    proof = get_merkle_proof_for_token(root_record, token_id)
    Rails.logger.info "[MatchEngine] 获取到Merkle proof，长度: #{proof&.size || 0}"

    if proof.nil?
      Rails.logger.warn "[MatchEngine] 无法获取token #{token_id} 的Merkle proof"
      return nil
    end

    if proof.empty? && root_record.token_count.to_i > 1
      Rails.logger.warn "[MatchEngine] token #{token_id} 的Merkle proof为空且token_count>1，视为无效"
      return nil
    end

    if proof.empty?
      Rails.logger.info "[MatchEngine] 单叶Merkle树允许空proof (token_count=#{root_record.token_count})"
    end

    criteria_resolver = {
      orderIndex: order_index,
      side: 1,
      index: 0,
      identifier: token_id,
      criteriaProof: proof
    }

    Rails.logger.info "[MatchEngine] ✅ 成功生成criteriaResolver:"
    Rails.logger.info "[MatchEngine]   orderIndex: #{criteria_resolver[:orderIndex]}"
    Rails.logger.info "[MatchEngine]   side: #{criteria_resolver[:side]}"
    Rails.logger.info "[MatchEngine]   index: #{criteria_resolver[:index]}"
    Rails.logger.info "[MatchEngine]   identifier: #{criteria_resolver[:identifier]}"
    Rails.logger.info "[MatchEngine]   criteriaProof长度: #{criteria_resolver[:criteriaProof].size}"
    Rails.logger.info "[MatchEngine] =========================================="

    criteria_resolver
  rescue => e
    Rails.logger.error "[MatchEngine] 生成criteriaResolver失败: #{e.message}"
    Rails.logger.error e.backtrace.first(3).join("\n")
    nil
  end

  def get_merkle_proof_for_token(root_record, token_id)
    leaf_node = Merkle::TreeNode.find_by(
      snapshot_id: root_record.snapshot_id,
      token_id: token_id.to_s,
      is_leaf: true
    )

    return nil unless leaf_node

    proof = []
    current_index = leaf_node.node_index
    current_level = leaf_node.level

    all_nodes = Merkle::TreeNode.where(snapshot_id: root_record.snapshot_id)
                                       .order(:level, :node_index)

    nodes_by_level = all_nodes.group_by(&:level)
    max_level = nodes_by_level.keys.max

    while current_level < max_level
      level_nodes = nodes_by_level[current_level] || []
      sibling_index = current_index.even? ? current_index + 1 : current_index - 1
      sibling_node = level_nodes.find { |n| n.node_index == sibling_index }
      proof << sibling_node.node_hash if sibling_node

      current_index /= 2
      current_level += 1
    end

    proof
  rescue => e
    Rails.logger.error "[MatchEngine] 获取Merkle proof失败: #{e.message}"
    nil
  end

  def clear_merkle_cache_for_root(merkle_root)
    Rails.logger.info "[MERKLE_CACHE] 清理Merkle根 #{merkle_root} 的相关缓存"
  end

  def preload_merkle_cache(bids, asks)
    cache_requests = []

    bids.each do |bid|
      bid_identifier = bid[3]
      next unless is_collection_order?(bid_identifier)

      asks.each do |ask|
        ask_identifier = ask[3]
        next if is_collection_order?(ask_identifier)

        cache_requests << {
          token_id: ask_identifier,
          merkle_root: bid_identifier,
          cache_key: "merkle_verify:#{bid_identifier}:#{ask_identifier}"
        }
      end
    end

    return if cache_requests.empty?

    Rails.logger.info "[MERKLE_CACHE] 开始预热缓存，需要验证 #{cache_requests.size} 个组合"

    uncached_requests = cache_requests.select do |req|
      Rails.cache.read(req[:cache_key]).nil?
    end

    if uncached_requests.empty?
      Rails.logger.info "[MERKLE_CACHE] 所有验证结果都已缓存，无需预热"
      return
    end

    Rails.logger.info "[MERKLE_CACHE] 需要查询数据库的组合数: #{uncached_requests.size}"

    uncached_requests.group_by { |req| req[:merkle_root] }.each do |merkle_root, group_requests|
      token_ids = group_requests.map { |req| req[:token_id].to_s }

      begin
        root_record = Merkle::TreeRoot.find_latest_active_by_root_hash(merkle_root)

        if root_record
          existing_token_ids = Merkle::TreeNode
            .where(snapshot_id: root_record.snapshot_id, token_id: token_ids, is_leaf: true)
            .pluck(:token_id)
            .map(&:to_s)

          group_requests.each do |req|
            result = existing_token_ids.include?(req[:token_id].to_s)
            cache_expiry = result ? 300 : 60
            Rails.cache.write(req[:cache_key], result, expires_in: cache_expiry)
          end

          Rails.logger.debug "[MERKLE_CACHE] 为Merkle根 #{merkle_root} 预热了 #{group_requests.size} 个缓存条目"
        else
          group_requests.each do |req|
            Rails.cache.write(req[:cache_key], false, expires_in: 60)
          end

          Rails.logger.warn "[MERKLE_CACHE] Merkle根 #{merkle_root} 不存在，设置 #{group_requests.size} 个false缓存"
        end
      rescue => e
        Rails.logger.error "[MERKLE_CACHE] 预热Merkle根 #{merkle_root} 缓存时出错: #{e.message}"

        group_requests.each do |req|
          Rails.cache.write(req[:cache_key], false, expires_in: 10)
        end
      end
    end

    Rails.logger.info "[MERKLE_CACHE] 缓存预热完成"
  end

  def group_orders_by_compatibility(bids, asks)
    compatible_groups = []
    grouped_specific_bids = Hash.new { |h, k| h[k] = [] }

    bids.each do |bid|
      bid_identifier = bid[3]

      if is_collection_order?(bid_identifier)
        Rails.logger.debug "[MatchEngine] 处理Collection买单，Merkle根: #{bid_identifier}"

        compatible_specific_asks = asks.select do |ask|
          ask_identifier = ask[3]

          if !is_collection_order?(ask_identifier)
            is_compatible = token_in_merkle_tree?(ask_identifier, bid_identifier)
            if is_compatible
              Rails.logger.debug "[MatchEngine] ✓ Collection买单可匹配Specific卖单 token_id: #{ask_identifier}"
            else
              Rails.logger.debug "[MatchEngine] ✗ Collection买单无法匹配Specific卖单 token_id: #{ask_identifier}"
            end
            is_compatible
          else
            false
          end
        end

        compatible_collection_asks = asks.select { |ask| ask[3] == bid_identifier }
        compatible_asks = compatible_specific_asks + compatible_collection_asks

        if compatible_asks.any?
          compatible_groups << {
            bids: [bid],
            asks: compatible_asks,
            type: 'collection_to_mixed',
            bid_identifier: bid_identifier
          }

          Rails.logger.debug "[MatchEngine] Collection买单找到 #{compatible_asks.size} 个兼容卖单 (#{compatible_specific_asks.size} specific + #{compatible_collection_asks.size} collection)"
        else
          Rails.logger.warn "[MatchEngine] Collection买单未找到兼容的卖单"
        end
      else
        grouped_specific_bids[bid_identifier] << bid
      end
    end

    grouped_specific_bids.each do |bid_identifier, specific_bids|
      compatible_asks = asks.select { |ask| ask[3] == bid_identifier }
      next if compatible_asks.empty?

      compatible_groups << {
        bids: specific_bids,
        asks: compatible_asks,
        type: 'specific_to_specific',
        bid_identifier: bid_identifier
      }

      Rails.logger.debug "[MatchEngine] Specific订单分组 token=#{bid_identifier}: bids=#{specific_bids.size}, asks=#{compatible_asks.size}"
    end

    Rails.logger.info "[MatchEngine] 总共生成 #{compatible_groups.size} 个兼容匹配组"
    compatible_groups
  end

  def build_criteria_resolvers_from_graph(match_orders, graph, orders_by_hash)
    criteria_resolvers = []
    groups_by_bid_hash = graph[:groups].each_with_object({}) do |group, memo|
      memo[group[:bid_hash].to_s] = group
    end

    match_orders.each do |match|
      next unless match['side'] == 'Offer'

      bid_hash = match.dig('bid', 2).to_s
      group = groups_by_bid_hash[bid_hash]
      next unless group

      bid_order = orders_by_hash[bid_hash]
      next unless bid_order

      is_collection_bid = bid_order.order_direction == 'Offer' && is_collection_order?(bid_order.consideration_identifier)
      next unless is_collection_bid

      group[:ask_hashes].each do |ask_hash|
        ask_order = orders_by_hash[ask_hash]
        next unless ask_order

        criteria = generate_criteria_resolver_for_order(
          group[:bid_order_index],
          ask_order,
          bid_order.consideration_identifier
        )
        criteria_resolvers << criteria if criteria
      end
    end

    criteria_resolvers
  end
end
