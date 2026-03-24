# frozen_string_literal: true

# spec/factories/markets.rb
# 市场工厂 - NFT 交易市场

FactoryBot.define do
  factory :market, class: 'Trading::Market' do
    sequence(:name) { |n| "Item#{n}" }
    sequence(:base_currency) { |n| "BC#{n}" }
    quote_currency { 'RON' }
    price_address { '0x0000000000000000000000000000000000000000' }
    sequence(:item_id) { |n| n + 27 } # 从 28 开始

    # market_id 在 after(:build) 中生成
    market_id { nil }

    # 处理 market_id 的生成
    after(:build) do |market|
      # 定义 quote_currency 到数字的映射
      currency_mapping = {
        'RON' => '00',
        'LUA' => '01',
        'USDC' => '02'
      }

      # 获取对应 quote_currency 的数字
      currency_number = currency_mapping[market.quote_currency] || '00'

      # 生成 market_id 为 "item_id + currency_number"
      market.market_id ||= "#{market.item_id}#{currency_number}"

      # 更新名称和基础货币
      market.name = "Item#{market.item_id}" if market.name.blank?
      market.base_currency = "BC#{market.item_id}" if market.base_currency.blank?
    end

    # === Traits ===

    # RON 计价市场
    trait :ron_market do
      quote_currency { 'RON' }
    end

    # LUA 计价市场
    trait :lua_market do
      quote_currency { 'LUA' }
    end

    # USDC 计价市场
    trait :usdc_market do
      quote_currency { 'USDC' }
    end

    # 特定物品的市场
    trait :for_item do
      transient do
        target_item_id { 28 }
      end

      item_id { target_item_id }
    end

    # 同质化物品市场 (itemId 28-38)
    trait :fungible do
      sequence(:item_id) { |n| 28 + (n % 11) }
    end

    # 非同质化物品市场 (itemId 39-47)
    trait :non_fungible do
      sequence(:item_id) { |n| 39 + (n % 9) }
    end
  end
end
