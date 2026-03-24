# frozen_string_literal: true

FactoryBot.define do
  factory :onchain_event_subscription, class: 'Onchain::EventSubscription' do
    sequence(:handler_key) { |n| "handler_#{n}" }
    abi_key { 'default_abi' }
    addresses { ['0x' + SecureRandom.hex(20)] }
    topics { [['0x' + SecureRandom.hex(32)]] }
    topic0_mapping { {} }
    start_block { 0 }
    block_window { 90 }
  end
end
