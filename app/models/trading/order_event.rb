module Trading
  class OrderEvent < ApplicationRecord
    # 数据库字段说明：
    # - event_name: 事件名称（如 OrderValidated, OrderFulfilled 等）
    # - order_hash: 订单哈希，用于唯一标识订单
    # - offerer: 提供订单的地址
    # - zone: 区域地址
    # - recipient: 收件人地址
    # - offer: 提供项详情（JSONB）
    # - consideration: 考虑项详情（JSONB）
    # - order_parameters: 订单参数详情（JSONB）

    # 验证
    validates :event_name, presence: true
    validates :order_hash, presence: true, unless: -> { event_name == 'OrdersMatched' }
    validates :transaction_hash, presence: true
    validates :log_index, presence: true
    validates :transaction_hash, uniqueness: { scope: :log_index }
    validates :block_number, presence: true
    validates :block_timestamp, presence: true

    # JSONB 数据处理,PostgreSQL 的 jsonb 类型本身支持原生的 JSON 存储和查询，不需要再通过 ActiveRecord 的 serialize 方法处理
    # serialize :offer, coder: JSON
    # serialize :consideration, coder: JSON
    # serialize :order_parameters, coder: JSON

    # 作用域
    scope :recent, -> { order(created_at: :desc) }
    scope :by_event_name, ->(name) { where(event_name: name) }
    scope :by_order_hash, ->(hash) { where(order_hash: hash) }


    # 注意：order_hash 不应该有唯一性约束，因为：
    # 1. 同一个订单可以被多次部分fulfill
    # 2. 同一个订单可以在不同交易中被fulfill
    # 3. 真正的唯一性由 transaction_hash + log_index 保证
  end
end
