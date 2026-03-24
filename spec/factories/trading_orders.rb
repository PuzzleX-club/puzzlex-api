# frozen_string_literal: true

# spec/factories/orders.rb
# 订单工厂 - 生成符合 Seaport 协议的订单数据

FactoryBot.define do
  factory :trading_order, class: 'Trading::Order' do
    # 唯一订单哈希
    sequence(:order_hash) { |n| "0x#{n.to_s.rjust(64, '0')}" }

    # Seaport 订单参数 (JSONB)
    parameters { {} }

    # 签名
    sequence(:signature) { |n| "0x#{Faker::Crypto.sha256}#{n.to_s(16).rjust(4, '0')}" }

    # 订单创建者地址
    offerer { Faker::Blockchain::Ethereum.address }

    # 时间范围
    start_time { Time.current.to_i.to_s }
    end_time { (Time.current + 7.days).to_i.to_s }

    # 提供物品 (卖出的 NFT)
    offer_token { Faker::Blockchain::Ethereum.address }
    sequence(:offer_identifier) do |n|
      # 使用结构化 Token ID
      item_id = ((n - 1) % 100) + 1
      quality = 1
      ((0x10 << 16) | (item_id << 8) | quality).to_s
    end

    # 考虑物品 (收到的代币)
    consideration_token { Faker::Blockchain::Ethereum.address }
    consideration_identifier { '0' } # ERC20 代币通常为 0

    counter { 0 }
    is_validated { false }
    is_cancelled { false }
    total_filled { 0 }
    total_size { 100 }

    # 订单方向: 'List' (卖单) 或 'Offer' (买单)
    order_direction { 'List' }

    # 价格
    start_price { 100.to_d }
    end_price { 90.to_d }

    # 数量
    consideration_start_amount { 100.to_d }
    consideration_end_amount { 90.to_d }
    offer_start_amount { 1.to_d }
    offer_end_amount { 1.to_d }

    # 状态
    onchain_status { 'pending' }
    offchain_status { 'active' }

    # JSONB 字段
    synced_at { {} }

    # 物品 ID
    offer_item_id { 28 }
    consideration_item_id { 0 }

    # 关联市场 (可选)
    # association :market

    # === Traits ===

    # 已验证的订单
    trait :validated do
      onchain_status { 'validated' }
      is_validated { true }
    end

    # 活跃订单
    trait :active do
      onchain_status { 'validated' }
      offchain_status { 'active' }
    end

    # 已取消的订单
    trait :cancelled do
      onchain_status { 'cancelled' }
      offchain_status { 'closed' }
      is_cancelled { true }
    end

    # 已完成的订单
    trait :fulfilled do
      onchain_status { 'filled' }
      offchain_status { 'closed' }
      total_filled { 100 }
    end

    # 部分成交的订单
    trait :partial_filled do
      onchain_status { 'partially_filled' }
      total_filled { 50 }
    end

    # 卖单 (List)
    trait :list do
      order_direction { 'List' }
    end

    # 买单 (Offer)
    trait :offer do
      order_direction { 'Offer' }
    end

    # 已过期的订单
    trait :expired do
      end_time { (Time.current - 1.day).to_i.to_s }
    end

    # 带市场关联
    trait :with_market do
      association :market, factory: :market
    end

    # 特定物品的订单
    trait :for_item do
      transient do
        item_id { 28 }
      end

      offer_item_id { item_id }
      offer_identifier do
        quality = 1
        ((0x10 << 16) | (item_id << 8) | quality).to_s
      end
    end
  end
end
