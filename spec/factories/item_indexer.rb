# frozen_string_literal: true

FactoryBot.define do
  # ============================================
  # Item Indexer Factories
  # All models use string primary keys (no auto-increment)
  # ============================================

  factory :indexer_item, class: 'ItemIndexer::Item' do
    sequence(:id) { |n| (100 + n).to_s }
    total_supply { 1000 }
    minted_amount { 1200 }
    burned_amount { 200 }
    last_updated { Time.current.to_i }
  end

  factory :indexer_instance, class: 'ItemIndexer::Instance' do
    # tokenId is a structured ID derived from itemId + quality
    sequence(:id) { |n| "10#{(100 + n).to_s(16).rjust(4, '0')}01" }
    association :item_record, factory: :indexer_item
    item { |attrs| attrs.item_record&.id || '100' }
    quality { '0x01' }
    total_supply { 500 }
    minted_amount { 600 }
    burned_amount { 100 }
    last_updated { Time.current.to_i }
    metadata_status { 'pending' }
    metadata_retry_count { 0 }

    trait :with_metadata do
      metadata_status { 'completed' }

      after(:create) do |instance|
        create(:indexer_metadata,
               instance_id: instance.id,
               item_id: instance.item)
      end
    end

    trait :with_attributes do
      after(:create) do |instance|
        create(:indexer_attribute,
               instance_id: instance.id,
               item_id: instance.item,
               trait_type: 'Quality',
               value_string: '1')
        create(:indexer_attribute,
               instance_id: instance.id,
               item_id: instance.item,
               trait_type: 'WealthValue',
               value_string: '100')
      end
    end
  end

  factory :indexer_player, class: 'ItemIndexer::Player' do
    sequence(:id) { |n| "0x#{n.to_s(16).rjust(40, '0')}" }
    address { |attrs| attrs.id }
  end

  factory :indexer_instance_balance, class: 'ItemIndexer::InstanceBalance' do
    transient do
      token_id { nil }
      player_address { nil }
    end

    association :instance_record, factory: :indexer_instance
    association :player_record, factory: :indexer_player
    instance { |attrs| attrs.instance_record&.id }
    player { |attrs| attrs.player_record&.id }
    id { |attrs| "#{attrs.instance}-#{attrs.player}" }
    balance { 10 }
    minted_amount { 10 }
    transferred_in_amount { 0 }
    transferred_out_amount { 0 }
    burned_amount { 0 }
    timestamp { Time.current.to_i }
  end

  factory :indexer_transaction, class: 'ItemIndexer::Transaction' do
    sequence(:id) { |n| "0x#{SecureRandom.hex(32)}-0-#{n}" }
    association :item_record, factory: :indexer_item
    association :instance_record, factory: :indexer_instance
    item { |attrs| attrs.item_record&.id }
    instance { |attrs| attrs.instance_record&.id }
    transaction_hash { "0x#{SecureRandom.hex(32)}" }
    log_index { 0 }
    block_number { rand(1_000_000..9_999_999) }
    block_hash { "0x#{SecureRandom.hex(32)}" }
    amount { 1 }
    from_address { "0x#{SecureRandom.hex(20)}" }
    to_address { "0x#{SecureRandom.hex(20)}" }
    timestamp { Time.current.to_i }

    trait :mint do
      from_address { '0x0000000000000000000000000000000000000000' }
    end

    trait :burn do
      to_address { '0x0000000000000000000000000000000000000000' }
    end

    trait :transfer do
      from_address { "0x#{SecureRandom.hex(20)}" }
      to_address { "0x#{SecureRandom.hex(20)}" }
    end
  end

  factory :indexer_metadata, class: 'ItemIndexer::Metadata' do
    instance_id { |attrs| attrs.association(:indexer_instance)&.id || "token-#{SecureRandom.hex(4)}" }
    item_id { '100' }
    name { Faker::Fantasy::Tolkien.character }
    description { Faker::Lorem.sentence }
    image { "https://example.com/images/#{SecureRandom.hex(8)}.png" }
    background_color { '#FF0000' }
    raw_metadata { { 'name' => name, 'description' => description, 'image' => image } }
    metadata_fetched_at { Time.current }
  end

  factory :indexer_attribute, class: 'ItemIndexer::Attribute' do
    instance_id { |attrs| attrs.association(:indexer_instance)&.id || "token-#{SecureRandom.hex(4)}" }
    item_id { '100' }
    trait_type { 'Quality' }
    value_string { '1' }
    display_type { nil }
  end
end
