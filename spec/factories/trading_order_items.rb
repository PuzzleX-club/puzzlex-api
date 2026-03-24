# frozen_string_literal: true

# spec/factories/order_items.rb
# 订单项工厂 - 遵循结构化 Token ID 规范

FactoryBot.define do
  factory :trading_order_item, class: 'Trading::OrderItem' do
    association :order, factory: :trading_order

    role { 'offer' } # NOT NULL: 'offer' 或 'consideration'

    # 使用 Faker 生成以太坊地址
    token_address { Faker::Blockchain::Ethereum.address }

    # ⚠️ 结构化 Token ID 规范
    # 格式: 0x10 + itemId(1字节) + quality(1字节)
    # 绝对禁止使用简单 ID 如 "1", "2", "3"
    sequence(:token_id) do |n|
      item_id = ((n - 1) % 100) + 1 # 1-100 循环
      quality = 1
      # 0x10 << 16 | itemId << 8 | quality
      ((0x10 << 16) | (item_id << 8) | quality).to_s
    end

    start_amount { 100.0 }
    end_amount { 50.0 }

    # JSONB 价格分配
    start_price_distribution do
      [
        {
          'token_address' => Faker::Blockchain::Ethereum.address,
          'item_type' => 0,
          'token_id' => '0',
          'recipients' => [
            { 'address' => Faker::Blockchain::Ethereum.address, 'amount' => '0.95' },
            { 'address' => Faker::Blockchain::Ethereum.address, 'amount' => '0.04' },
            { 'address' => Faker::Blockchain::Ethereum.address, 'amount' => '0.01' }
          ]
        }
      ]
    end

    end_price_distribution do
      [
        {
          'token_address' => Faker::Blockchain::Ethereum.address,
          'item_type' => 0,
          'token_id' => '0',
          'recipients' => [
            { 'address' => Faker::Blockchain::Ethereum.address, 'amount' => '0.90' },
            { 'address' => Faker::Blockchain::Ethereum.address, 'amount' => '0.05' },
            { 'address' => Faker::Blockchain::Ethereum.address, 'amount' => '0.05' }
          ]
        }
      ]
    end

    # === Traits ===

    # 卖单项 (List - 卖出 NFT 换取代币)
    trait :offer_item do
      role { 'offer' }
    end

    # 买单项 (Offer - 用代币买入 NFT)
    trait :consideration_item do
      role { 'consideration' }
    end

    # 高品质物品 (quality = 255)
    trait :high_quality do
      token_id do
        item_id = rand(1..100)
        quality = 255
        ((0x10 << 16) | (item_id << 8) | quality).to_s
      end
    end

    # 特定 itemId 的物品
    trait :with_item_id do
      transient do
        item_id { 28 } # 默认测试物品
        quality { 1 }
      end

      token_id do
        ((0x10 << 16) | (item_id << 8) | quality).to_s
      end
    end

    # 大额数量
    trait :large_amount do
      start_amount { 10_000.0 }
      end_amount { 5_000.0 }
    end
  end
end
