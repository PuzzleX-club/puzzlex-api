# frozen_string_literal: true

# spec/factories/order_fills.rb
# 订单成交记录工厂

FactoryBot.define do
  factory :trading_order_fill, class: 'Trading::OrderFill' do
    association :order, factory: :trading_order
    association :order_item, factory: :trading_order_item
    # 注意：移除 market 关联，因为 Trading::Market 有 payment_type enum 问题
    # market_id 字段会在下面单独设置

    filled_amount { 1.0 }

    # JSONB 价格分配
    # ⚠️ token_id 使用结构化格式
    price_distribution do
      # 生成结构化 token_id
      item_id = rand(1..100)
      quality = 1
      structured_token_id = ((0x10 << 16) | (item_id << 8) | quality).to_s

      [
        {
          'token_address' => Faker::Blockchain::Ethereum.address,
          'item_type' => 2, # ERC721/ERC1155
          'token_id' => structured_token_id,
          'recipients' => [
            { 'address' => Faker::Blockchain::Ethereum.address, 'amount' => '300' },
            { 'address' => Faker::Blockchain::Ethereum.address, 'amount' => '300' }
          ],
          'total_amount' => '600'
        }
      ]
    end

    sequence(:transaction_hash) { |n| "0x#{Faker::Crypto.sha256[0..62]}#{n.to_s(16).rjust(2, '0')}" }
    market_id { 2800 } # 默认市场 ID
    log_index { 0 }
    block_timestamp { Time.current.to_i }

    # === Traits ===

    # 大额成交
    trait :large_fill do
      filled_amount { 100.0 }
    end

    # 小额成交
    trait :small_fill do
      filled_amount { 0.1 }
    end

    # 特定市场的成交
    trait :for_market do
      transient do
        target_market_id { 2800 }
      end

      market_id { target_market_id }
    end

    # ERC20 代币成交 (token_id = 0)
    trait :erc20_fill do
      price_distribution do
        [
          {
            'token_address' => Faker::Blockchain::Ethereum.address,
            'item_type' => 1, # ERC20
            'token_id' => '0',
            'recipients' => [
              { 'address' => Faker::Blockchain::Ethereum.address, 'amount' => '1000' }
            ],
            'total_amount' => '1000'
          }
        ]
      end
    end
  end
end
