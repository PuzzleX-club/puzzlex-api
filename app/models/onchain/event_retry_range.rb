module Onchain
  class EventRetryRange < ApplicationRecord
    # 验证
    validates :event_type, presence: true
    validates :from_block, presence: true, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
    validates :to_block, presence: true, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
    validates :attempts, presence: true, numericality: { only_integer: true, greater_than_or_equal_to: 0 }

    # 自定义验证：from_block 必须小于等于 to_block
    validate :from_block_must_be_less_than_or_equal_to_to_block

    private

    def from_block_must_be_less_than_or_equal_to_to_block
      if from_block.present? && to_block.present? && from_block > to_block
        errors.add(:from_block, "must be less than or equal to to_block")
      end
    end
  end
end
