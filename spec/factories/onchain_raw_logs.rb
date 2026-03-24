# frozen_string_literal: true

FactoryBot.define do
  factory :onchain_raw_log, class: 'Onchain::RawLog' do
    address { '0x' + SecureRandom.hex(20) }
    topic0 { '0x' + SecureRandom.hex(32) }
    topics { [] }
    data { '0x' }
    block_number { rand(1..100_000) }
    transaction_hash { '0x' + SecureRandom.hex(32) }
    log_index { 0 }
  end
end
