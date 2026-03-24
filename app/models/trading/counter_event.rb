module Trading
  class CounterEvent < ApplicationRecord
    # 数据库字段说明：
    # - event_name: 事件名称（如 CounterIncremented 等）
    # - new_counter: 最新的计数值
    # - offerer: 提供者地址

    # 验证
    validates :event_name, presence: true
    validates :offerer, presence: true
    validates :transaction_hash, presence: true
    validates :log_index, presence: true
    validates :transaction_hash, uniqueness: { scope: :log_index }
    validates :block_number, presence: true
    validates :block_timestamp, presence: true

    # 作用域
    scope :recent, -> { order(created_at: :desc) }
    scope :by_offerer, ->(address) { where(offerer: address) }
  end
end
