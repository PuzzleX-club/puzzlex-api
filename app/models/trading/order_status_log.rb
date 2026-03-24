# frozen_string_literal: true
# 订单状态变更审计日志

module Trading
  class OrderStatusLog < ApplicationRecord

    belongs_to :order, class_name: "Trading::Order"

    validates :status_type, presence: true
    validates :to_status, presence: true
    validates :changed_at, presence: true

    def self.log!(order:, status_type:, from_status:, to_status:, reason: nil, metadata: {})
      create!(
        order: order,
        status_type: status_type.to_s,
        from_status: from_status,
        to_status: to_status,
        reason: reason,
        metadata: metadata,
        changed_at: Time.current
      )
    end
  end
end
