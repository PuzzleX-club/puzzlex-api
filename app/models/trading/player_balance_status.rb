module Trading
  class PlayerBalanceStatus < ApplicationRecord

    # 验证
    validates :player_address, presence: true
    validates :resource_type, presence: true, inclusion: { in: %w[token currency] }
    validates :resource_id, presence: true
    validates :required_amount, presence: true, numericality: { greater_than_or_equal_to: 0 }
    validates :available_amount, presence: true, numericality: { greater_than_or_equal_to: 0 }
    validates :over_matched_orders_count, presence: true, numericality: { greater_than_or_equal_to: 0 }
    validates :last_checked_at, presence: true

    # 唯一性约束
    validates :player_address, uniqueness: { scope: [:resource_type, :resource_id] }

    # 作用域
    scope :insufficient, -> { where(is_sufficient: false) }
    scope :sufficient, -> { where(is_sufficient: true) }
    scope :for_player, ->(address) { where(player_address: address) }
    scope :for_token, ->(item_id) { where(resource_type: 'token', resource_id: item_id) }
    scope :for_currency, ->(currency_address) { where(resource_type: 'currency', resource_id: currency_address) }
    scope :recently_checked, ->(hours = 1) { where(last_checked_at: hours.hours.ago..Time.current) }

    # 便捷方法
    def self.find_or_initialize_for_resource(player_address, resource_type, resource_id)
      find_or_initialize_by(
        player_address: player_address,
        resource_type: resource_type,
        resource_id: resource_id
      )
    end

    def update_status(required:, available:, over_matched_count: 0)
      self.required_amount = required
      self.available_amount = available
      self.is_sufficient = available >= required
      self.over_matched_orders_count = over_matched_count
      self.last_checked_at = Time.current
      save!
    end

    def shortage_amount
      return 0 if is_sufficient?
      required_amount - available_amount
    end

    def resource_description
      case resource_type
      when 'token'
        "物品ID: #{resource_id}"
      when 'currency'
        "货币: #{resource_id}"
      else
        "未知资源: #{resource_id}"
      end
    end

    def status_description
      if is_sufficient?
        "余额充足 (#{available_amount}/#{required_amount})"
      else
        "余额不足 (#{available_amount}/#{required_amount}，缺少 #{shortage_amount})"
      end
    end
  end
end
