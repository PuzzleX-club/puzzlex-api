module Onchain
  class EventListenerStatus < ApplicationRecord
    # 验证
    validates :last_processed_block, presence: true
    validates :event_type, presence: true

    # 更新状态 - 支持 event_type 参数，默认为 'global'
    # event_name 参数保留用于向后兼容，但实际使用 event_type
    def self.update_status(event_name = nil, block_number, event_type: nil)
      type = event_type || event_name || 'global'
      record = find_or_initialize_by(event_type: type)
      record.update(last_processed_block: block_number, last_updated_at: Time.current)
    end

    # 获取上次处理的区块高度 - 支持 event_type 参数
    # event_name 参数保留用于向后兼容
    def self.last_block(event_name = nil, event_type: nil)
      type = event_type || event_name || 'global'
      find_by(event_type: type)&.last_processed_block || "earliest"
    end
  end
end
