FactoryBot.define do
  factory :merkle_tree_root, class: 'Merkle::TreeRoot' do
    root_hash { "0x1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef" }
    item_id { 14601 }
    snapshot_id { 'snap_001' }
    token_count { 3 }
    tree_exists { true }
    expires_at { 10.days.from_now }
    usage_count { 0 }
    last_used_at { nil }
    tree_deleted_at { nil }
    metadata { '{}' }
    
    trait :expired do
      tree_exists { false }
      tree_deleted_at { 1.day.ago }
    end
    
    trait :with_different_root do
      root_hash { "0x9876543210fedcba9876543210fedcba9876543210fedcba9876543210fedcba" }
      snapshot_id { 'snap_002' }
    end
  end
end 