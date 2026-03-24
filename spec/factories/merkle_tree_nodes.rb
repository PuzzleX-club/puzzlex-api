FactoryBot.define do
  factory :merkle_tree_node, class: 'Merkle::TreeNode' do
    snapshot_id { 'snap_001' }
    token_id { 14601 }
    node_index { 0 }
    level { 0 }
    is_leaf { true }
    is_root { false }
    node_hash { 'leaf_hash_1' }
    item_id { 14601 }
    
    trait :as_root do
      is_root { true }
      is_leaf { false }
      level { 3 }
      node_index { 0 }
      token_id { nil }
      node_hash { 'root_hash' }
    end
    
    trait :as_internal_node do
      is_leaf { false }
      is_root { false }
      level { 1 }
      token_id { nil }
      node_hash { 'internal_hash' }
    end
  end
end 