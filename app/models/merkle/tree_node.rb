# app/models/merkle/tree_node.rb

module Merkle
  class TreeNode < Merkle::ApplicationRecord
    validates :snapshot_id, :node_index, :level, :node_hash, presence: true

    # 可以根据需要添加一些辅助方法，例如计算 Proof 路径时使用的查询函数
    def self.get_node(snapshot_id, node_index)
      find_by(snapshot_id: snapshot_id, node_index: node_index)
    end

    def self.get_root(item_id)
      root_node = find_by(item_id: item_id, is_root: true)
      root_node ? root_node.node_hash : nil
    end

    def self.verify_token(token_id)
      # 查找对应的叶子节点，确保 token_id 存在于树中（叶子节点记录 token_id）
      leaf = find_by(token_id: token_id, is_leaf: true)
      return false if leaf.nil?

      item_id = ::Blockchain::TokenIdParser.new.item_id_int(token_id) || 0

      # 根据叶子节点的 snapshot_id 获取对应的根节点记录
      root = find_by(snapshot_id: leaf.snapshot_id, is_root: true)
      return false if root.nil?

      # 验证根节点中的 item_id 是否与传入的 item_id 匹配
      root.item_id.to_s == item_id.to_s
    end

    def self.get_proof(token_id)
      # 查找叶子节点
      leaf = find_by(token_id: token_id)
      return [] if leaf.nil?

      proof = []
      current_node = leaf

      # 循环遍历直到到达根节点（level为最后一层）
      while current_node.level < highest_level(current_node.snapshot_id)
        # 计算兄弟节点的索引：如果当前节点 index 为偶数，则兄弟索引为 index+1；为奇数则 index-1
        sibling_index = current_node.node_index.even? ? current_node.node_index + 1 : current_node.node_index - 1
        sibling = find_by(snapshot_id: current_node.snapshot_id, level: current_node.level, node_index: sibling_index)

        # 如果当前层的节点数为奇数，最后一个节点没有对应的兄弟，
        # 则按构建树时的逻辑，重复最后一个节点，也就是证明中也应当加入当前节点的哈希
        if sibling.nil?
          sibling_hash = current_node.node_hash
        else
          sibling_hash = sibling.node_hash
        end

        proof << sibling_hash

        # 计算父节点索引（0-based）：父节点索引 = current_node.node_index / 2（整数除法）
        parent_index = current_node.node_index / 2

        # 移动到上层，level + 1
        current_node = find_by(snapshot_id: current_node.snapshot_id, level: current_node.level + 1, node_index: parent_index)
        break if current_node.nil?
      end

      proof
    end

    # 通过criteria（根节点hash）查找对应的item_id
    # 参数：criteria_hash - 根节点的hash值
    # 返回：item_id 或 nil（如果找不到或不是有效的根节点）
    def self.get_item_id_by_criteria(criteria_hash)
      return nil if criteria_hash.blank?

      # 首先查找最新的活跃根节点记录
      root_record = Merkle::TreeRoot.find_latest_active_by_root_hash(criteria_hash)

      if root_record.nil?
        Rails.logger.warn "[MerkleTreeNode] 未找到criteria #{criteria_hash} 对应的活跃根节点记录"
        return nil
      end

      Rails.logger.info "[MerkleTreeNode] ✓ 通过criteria #{criteria_hash} 找到 item_id: #{root_record.item_id}"
      root_record.item_id
    end

    # 获取指定item_id的最新可用根节点
    # 返回最新的根节点hash，用于创建新订单
    def self.get_latest_root(item_id)
      latest_root = Merkle::TreeRoot.latest_active_root(item_id)

      if latest_root.nil?
        Rails.logger.warn "[MerkleTreeNode] item_id #{item_id} 没有可用的Merkle树根节点"
        return nil
      end

      # 检查根节点是否过旧（超过8天则警告，因为订单最长7天）
      age_days = (Time.current - latest_root.created_at) / 1.day
      if age_days > 8
        Rails.logger.warn "[MerkleTreeNode] item_id #{item_id} 的最新根节点已有 #{age_days.round(1)} 天，可能过旧"
      end

      Rails.logger.info "[MerkleTreeNode] ✓ item_id #{item_id} 最新根节点: #{latest_root.root_hash[0..10]}... (#{age_days.round(1)}天前)"
      latest_root.root_hash
    end

    # 验证根节点是否在有效期内（用于订单创建时检查）
    def self.validate_root_for_order(criteria_hash, order_expiry_time)
      root_record = Merkle::TreeRoot.find_latest_active_by_root_hash(criteria_hash)

      if root_record.nil?
        return { valid: false, reason: "根节点不存在或已过期" }
      end

      # 检查根节点创建时间是否在订单到期时间之前足够时间
      # 确保订单有效期内该根节点都可用
      node_age = Time.current - root_record.created_at
      order_duration = order_expiry_time - Time.current

      # 如果根节点年龄 + 订单剩余时间 > 10天，则可能在订单到期前被清理
      if node_age + order_duration > 10.days
        return {
          valid: false,
          reason: "根节点可能在订单到期前被清理，请使用更新的根节点"
        }
      end

      { valid: true, reason: "根节点有效" }
    end

    # 获取指定item_id所有可用的根节点（按时间倒序）
    def self.get_available_roots(item_id, limit = 10)
      Merkle::TreeRoot.all_roots_for_item(item_id, limit)
    end

    # 辅助方法：获取指定 snapshot_id 下的最高层级（根节点所在层级）
    def self.highest_level(snapshot_id)
      # 假设根节点的 is_root 为 true，可以直接查找根节点来获取最高层级
      root_node = find_by(snapshot_id: snapshot_id, is_root: true)
      root_node ? root_node.level : 0
    end
  end
end
