# frozen_string_literal: true

FactoryBot.define do
  factory :trading_order_event, class: 'Trading::OrderEvent' do
    sequence(:order_hash) { |n| "0x#{n.to_s.rjust(64, '0')}" }
    event_name { 'OrderValidated' }
    sequence(:transaction_hash) { |n| "0x#{SecureRandom.hex(31)}#{n.to_s(16).rjust(2, '0')}" }
    sequence(:log_index) { |n| n }
    block_number { rand(1000000..2000000) }
    block_timestamp { Time.current.to_i }
    offerer { "0x#{SecureRandom.hex(20)}" }
    zone { "0x#{SecureRandom.hex(20)}" }
    recipient { "0x#{SecureRandom.hex(20)}" }

    # 默认 offer 数据 (NFT for List order)
    offer do
      [
        {
          'token' => SecureRandom.hex(20),
          'itemType' => 2,
          'identifierOrCriteria' => '1048833',
          'startAmount' => '1',
          'endAmount' => '1'
        }
      ].to_json
    end

    # 默认 consideration 数据 (ERC20)
    consideration do
      [
        {
          'token' => SecureRandom.hex(20),
          'itemType' => 1,
          'identifierOrCriteria' => '0',
          'startAmount' => '100000000000000000',
          'endAmount' => '100000000000000000',
          'recipient' => "0x#{SecureRandom.hex(20)}"
        }
      ].to_json
    end

    trait :order_validated do
      event_name { 'OrderValidated' }
    end

    trait :order_fulfilled do
      event_name { 'OrderFulfilled' }
      # OrderFulfilled 使用 identifier 和 amount 而不是 identifierOrCriteria
      offer do
        [
          {
            'token' => SecureRandom.hex(20),
            'itemType' => 2,
            'identifier' => '1048833',
            'amount' => '1'
          }
        ].to_json
      end
      consideration do
        [
          {
            'token' => SecureRandom.hex(20),
            'itemType' => 1,
            'identifier' => '0',
            'amount' => '100000000000000000',
            'recipient' => "0x#{SecureRandom.hex(20)}"
          }
        ].to_json
      end
    end

    trait :order_cancelled do
      event_name { 'OrderCancelled' }
    end

    trait :orders_matched do
      event_name { 'OrdersMatched' }
      order_hash { nil }
      matched_orders { ['0x1111111111111111111111111111111111111111111111111111111111111111'].to_json }
    end
  end
end