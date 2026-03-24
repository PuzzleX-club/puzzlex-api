# app/models/merkle/tree_root.rb
module Merkle
  class TreeRoot < Merkle::ApplicationRecord
    # 验证
    validates :root_hash, presence: true
    # 移除唯一性约束，允许相同的root_hash在不同时间存在多条记录
    # 这样可以保留完整的历史数据，支持审计追踪
    validates :item_id, presence: true
    validates :snapshot_id, presence: true
    validates :token_count, presence: true, numericality: { greater_than: 0 }

    # 作用域
    scope :active, -> { where(tree_exists: true) }
    scope :deleted, -> { where(tree_exists: false) }
    scope :for_item, ->(item_id) { where(item_id: item_id) }
    scope :recent, -> { order(created_at: :desc) }

    # 关联
    has_many :merkle_tree_nodes,
             class_name: 'Merkle::TreeNode',
             foreign_key: :snapshot_id,
             primary_key: :snapshot_id

    # 类方法

    # 创建新的根节点记录
    def self.create_root_record(root_hash, item_id, snapshot_id, token_count, metadata = {})
      # 计算预期过期时间
      expires_at = Time.current + 10.days

      create!(
        root_hash: root_hash,
        item_id: item_id,
        snapshot_id: snapshot_id,
        token_count: token_count,
        tree_exists: true,
        expires_at: expires_at,
        metadata: metadata.to_json
      )
    end

    # 根据root_hash查找根节点信息
    # 注意：如果存在多条相同root_hash的记录，将返回最新创建的记录
    def self.find_by_root_hash(root_hash)
      where(root_hash: root_hash).recent.first
    end

    # 根据root_hash查找最新的活跃根节点
    def self.find_latest_active_by_root_hash(root_hash)
      active.where(root_hash: root_hash).recent.first
    end

    # 获取指定item_id的最新有效根节点
    def self.latest_active_root(item_id)
      active.for_item(item_id).recent.first
    end

    # 获取指定item_id的所有根节点（包括已删除的）
    def self.all_roots_for_item(item_id, limit = 20)
      for_item(item_id).recent.limit(limit).map do |root|
        {
          root_hash: root.root_hash,
          created_at: root.created_at,
          token_count: root.token_count,
          tree_exists: root.tree_exists,
          tree_deleted_at: root.tree_deleted_at,
          age_hours: ((Time.current - root.created_at) / 1.hour).round(1),
          status: root.tree_exists ? 'active' : 'deleted'
        }
      end
    end

    # 检查根节点状态并返回详细信息
    def self.check_root_status(root_hash)
      root = find_by_root_hash(root_hash)

      if root.nil?
        return {
          exists: false,
          status: 'not_found',
          message: '根节点不存在',
          root_hash: root_hash
        }
      end

      age_days = (Time.current - root.created_at) / 1.day

      if root.tree_exists
        status = age_days > 8 ? 'active_but_old' : 'active'
        message = age_days > 8 ? "根节点有效但较旧 (#{age_days.round(1)}天前)" : "根节点有效"
      else
        status = 'expired'
        message = "根节点已过期 (#{age_days.round(1)}天前创建，于#{((Time.current - root.tree_deleted_at) / 1.day).round(1)}天前删除)"
      end

      {
        exists: true,
        status: status,
        message: message,
        root_hash: root.root_hash,
        item_id: root.item_id,
        token_count: root.token_count,
        created_at: root.created_at,
        tree_exists: root.tree_exists,
        tree_deleted_at: root.tree_deleted_at,
        age_days: age_days.round(1)
      }
    end

    # 标记根节点对应的树为已删除
    def self.mark_trees_as_deleted(snapshot_ids)
      where(snapshot_id: snapshot_ids).update_all(
        tree_exists: false,
        tree_deleted_at: Time.current
      )
    end

    # 获取统计信息
    def self.statistics
      total_roots = count
      active_roots = active.count
      deleted_roots = deleted.count
      items_count = distinct.count(:item_id)

      {
        total_roots: total_roots,
        active_roots: active_roots,
        deleted_roots: deleted_roots,
        items_with_roots: items_count,
        oldest_active: active.minimum(:created_at),
        newest_root: maximum(:created_at)
      }
    end

    # 记录根节点使用情况
    def self.record_usage(root_hash)
      root = find_by_root_hash(root_hash)
      return false if root.nil?

      root.update(
        usage_count: root.usage_count + 1,
        last_used_at: Time.current
      )
      true
    end

    # 获取使用统计最多的根节点
    def self.most_used_roots(limit = 10)
      where('usage_count > 0')
        .order(usage_count: :desc)
        .limit(limit)
        .pluck(:root_hash, :item_id, :usage_count, :last_used_at)
        .map { |hash, item_id, count, last_used|
          {
            root_hash: hash,
            item_id: item_id,
            usage_count: count,
            last_used_at: last_used
          }
        }
    end

    # 实例方法

    # 检查是否即将过期（基于7天订单限制 + 3天安全余量）
    def will_expire_soon?
      return false unless tree_exists

      age_days = (Time.current - created_at) / 1.day
      age_days > 8 # 超过8天认为即将过期
    end

    # 是否适合新订单使用
    def suitable_for_new_order?(order_duration_days = 7)
      return false unless tree_exists

      age_days = (Time.current - created_at) / 1.day
      # 确保根节点在订单有效期内不会被清理
      (age_days + order_duration_days) <= 10
    end

    # 解析metadata
    def parsed_metadata
      return {} if metadata.blank?
      JSON.parse(metadata)
    rescue JSON::ParserError
      {}
    end
  end
end
