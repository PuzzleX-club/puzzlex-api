module Trading
  class OrderStatusBackup < ApplicationRecord
    # DB列为 original_off_chain_status，历史调用使用 original_offchain_status
    alias_attribute :original_offchain_status, :original_off_chain_status

    # 验证
    validates :order_hash, presence: true
    validates :over_matched_reason, presence: true
    validates :resource_id, presence: true
    validates :backed_up_at, presence: true

    # 关联
    belongs_to :order, foreign_key: :order_hash, primary_key: :order_hash,
               class_name: 'Trading::Order', optional: true

    # 作用域
    scope :active, -> { where(is_active: true) }
    scope :restored, -> { where(is_active: false) }
    scope :for_order, ->(order_hash) { where(order_hash: order_hash) }
    scope :by_reason, ->(reason) { where(over_matched_reason: reason) }
    scope :by_resource, ->(resource_id) { where(resource_id: resource_id) }
    scope :recent, ->(days = 7) { where(backed_up_at: days.days.ago..Time.current) }

    # 超匹配原因常量
    OVER_MATCHED_REASONS = {
      'token_insufficient' => 'Token余额不足',
      'currency_insufficient' => '对价货币余额不足'
    }.freeze

    # 便捷方法
    def self.create_backup!(order, reason, resource_id)
      create!(
        order_hash: order.order_hash,
        original_off_chain_status: order.offchain_status,
        over_matched_reason: reason,
        resource_id: resource_id,
        backed_up_at: Time.current,
        is_active: true
      )
    end

    def restore!
      update!(
        is_active: false,
        restored_at: Time.current
      )
    end

    def reason_description
      OVER_MATCHED_REASONS[over_matched_reason] || over_matched_reason
    end

    def duration_in_over_matched
      return nil unless restored_at
      restored_at - backed_up_at
    end

    def duration_description
      return "仍在超匹配状态" if is_active?

      duration = duration_in_over_matched
      return "未知" unless duration

      if duration < 1.hour
        "#{(duration / 1.minute).round}分钟"
      elsif duration < 1.day
        "#{(duration / 1.hour).round(1)}小时"
      else
        "#{(duration / 1.day).round(1)}天"
      end
    end

    def resource_description
      case over_matched_reason
      when 'token_insufficient'
        "物品ID: #{resource_id}"
      when 'currency_insufficient'
        "货币: #{resource_id}"
      else
        "资源: #{resource_id}"
      end
    end

    # 统计方法
    def self.statistics_for_player(player_address, days = 7)
      joins(:order)
        .where(trading_orders: { offerer: player_address })
        .recent(days)
        .group(:over_matched_reason)
        .count
    end

    def self.statistics_by_resource(days = 7)
      recent(days)
        .group(:resource_id, :over_matched_reason)
        .count
    end
  end
end
