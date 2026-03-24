# spec/services/matching/collection_specific_matching_spec.rb
require 'rails_helper'

RSpec.describe Matching::Engine, type: :service do
  let(:market_id) { 1 }
  let(:match_engine) { described_class.new(market_id) }
  
  # 测试数据：Merkle根哈希（66位）
  let(:merkle_root_hash) { "0x1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef" }
  let(:another_merkle_root) { "0x9876543210fedcba9876543210fedcba9876543210fedcba9876543210fedcba" }
  
  # 测试数据：具体token_id
  let(:token_id_1) { "14601" }
  let(:token_id_2) { "14602" }
  let(:token_id_3) { "14603" }

  before do
    # 使用 ServiceTestHelpers 提供的 stub 方法
    stub_redis
    stub_action_cable
    stub_sidekiq_workers

    # 创建测试用的Merkle树数据
    @merkle_root = create(:merkle_tree_root, 
      root_hash: merkle_root_hash,
      item_id: 14601,
      snapshot_id: 'snap_001',
      token_count: 3,
      tree_exists: true
    )
    
    # 创建叶子节点，包含测试的token_id
    create(:merkle_tree_node,
      snapshot_id: 'snap_001',
      token_id: 14601,
      node_index: 0,
      level: 0,
      is_leaf: true,
      node_hash: 'leaf_hash_1'
    )
    
    create(:merkle_tree_node,
      snapshot_id: 'snap_001', 
      token_id: 14602,
      node_index: 1,
      level: 0,
      is_leaf: true,
      node_hash: 'leaf_hash_2'  
    )
    
    # token_id_3 不在这个Merkle树中
  end

  describe '#is_collection_order?' do
    it '正确识别Collection订单（66位0x开头哈希）' do
      expect(match_engine.is_collection_order?(merkle_root_hash)).to be true
    end
    
    it '正确识别Specific订单（token_id）' do
      expect(match_engine.is_collection_order?(token_id_1)).to be false
      expect(match_engine.is_collection_order?("12345")).to be false
    end
    
    it '处理边界情况' do
      expect(match_engine.is_collection_order?(nil)).to be false
      expect(match_engine.is_collection_order?("")).to be false
      expect(match_engine.is_collection_order?("0x123")).to be false  # 长度不够
      expect(match_engine.is_collection_order?("1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef12")).to be false  # 没有0x前缀
    end
  end

  describe '#token_in_merkle_tree?' do
    it '验证token_id在Merkle树中' do
      expect(match_engine.token_in_merkle_tree?(token_id_1, merkle_root_hash)).to be true
      expect(match_engine.token_in_merkle_tree?(token_id_2, merkle_root_hash)).to be true
    end
    
    it '验证token_id不在Merkle树中' do
      expect(match_engine.token_in_merkle_tree?(token_id_3, merkle_root_hash)).to be false
    end
    
    it '处理不存在的Merkle根' do
      expect(match_engine.token_in_merkle_tree?(token_id_1, another_merkle_root)).to be false
    end
    
    it '处理无效输入' do
      expect(match_engine.token_in_merkle_tree?(nil, merkle_root_hash)).to be false
      expect(match_engine.token_in_merkle_tree?(token_id_1, nil)).to be false
      expect(match_engine.token_in_merkle_tree?("", merkle_root_hash)).to be false
    end
  end
  
  describe '#group_orders_by_compatibility' do
    let(:collection_bid) { [100.0, 5.0, 'bid_hash_1', merkle_root_hash, 1640995200] }
    let(:specific_bid) { [95.0, 3.0, 'bid_hash_2', token_id_1, 1640995200] }
    
    let(:compatible_ask_1) { [90.0, 2.0, 'ask_hash_1', token_id_1, 1640995200] }
    let(:compatible_ask_2) { [92.0, 1.0, 'ask_hash_2', token_id_2, 1640995200] }
    let(:incompatible_ask) { [88.0, 1.0, 'ask_hash_3', token_id_3, 1640995200] }
    let(:collection_ask) { [85.0, 4.0, 'ask_hash_4', merkle_root_hash, 1640995200] }

    context 'Collection买单匹配Specific卖单' do
      it '正确匹配兼容的token_id' do
        bids = [collection_bid]
        asks = [compatible_ask_1, compatible_ask_2, incompatible_ask]
        
        groups = match_engine.group_orders_by_compatibility(bids, asks)
        
        expect(groups.size).to eq(1)
        group = groups.first
        
        expect(group[:type]).to eq('collection_to_mixed')
        expect(group[:bids]).to eq([collection_bid])
        expect(group[:asks].size).to eq(2)
        expect(group[:asks]).to include(compatible_ask_1, compatible_ask_2)
        expect(group[:asks]).not_to include(incompatible_ask)
      end
      
      it '同时匹配Specific和Collection卖单' do
        bids = [collection_bid]
        asks = [compatible_ask_1, collection_ask, incompatible_ask]
        
        groups = match_engine.group_orders_by_compatibility(bids, asks)
        
        expect(groups.size).to eq(1)
        group = groups.first
        
        expect(group[:asks].size).to eq(2)
        expect(group[:asks]).to include(compatible_ask_1, collection_ask)
        expect(group[:asks]).not_to include(incompatible_ask)
      end
    end
    
    context 'Specific买单匹配' do
      it '只匹配相同token_id的卖单' do
        bids = [specific_bid]
        asks = [compatible_ask_1, compatible_ask_2, incompatible_ask]
        
        groups = match_engine.group_orders_by_compatibility(bids, asks)
        
        expect(groups.size).to eq(1)
        group = groups.first
        
        expect(group[:type]).to eq('specific_to_specific')
        expect(group[:bids]).to eq([specific_bid])
        expect(group[:asks]).to eq([compatible_ask_1])  # 只有token_id_1匹配
      end
    end
    
    context '混合订单场景' do
      it '同时处理Collection和Specific买单' do
        bids = [collection_bid, specific_bid]
        asks = [compatible_ask_1, compatible_ask_2, incompatible_ask, collection_ask]
        
        groups = match_engine.group_orders_by_compatibility(bids, asks)
        
        expect(groups.size).to eq(2)
        
        collection_group = groups.find { |g| g[:type] == 'collection_to_mixed' }
        specific_group = groups.find { |g| g[:type] == 'specific_to_specific' }
        
        expect(collection_group).not_to be_nil
        expect(specific_group).not_to be_nil
        
        # Collection组应该包含3个卖单（2个compatible specific + 1个collection）
        expect(collection_group[:asks].size).to eq(3)
        expect(collection_group[:asks]).to include(compatible_ask_1, compatible_ask_2, collection_ask)
        
        # Specific组应该只包含1个匹配的卖单
        expect(specific_group[:asks].size).to eq(1)
        expect(specific_group[:asks]).to include(compatible_ask_1)
      end
    end
    
    context '无匹配情况' do
      it 'Collection买单无compatible卖单时返回空组' do
        bids = [collection_bid]
        asks = [incompatible_ask]  # token_id_3不在Merkle树中
        
        groups = match_engine.group_orders_by_compatibility(bids, asks)
        
        expect(groups).to be_empty
      end
      
      it 'Specific买单无匹配卖单时返回空组' do
        bids = [specific_bid]  # token_id_1
        asks = [compatible_ask_2, incompatible_ask]  # 只有token_id_2和token_id_3
        
        groups = match_engine.group_orders_by_compatibility(bids, asks)
        
        expect(groups).to be_empty
      end
    end
  end
  
  describe '集成测试：完整匹配流程' do
    let(:order_book_data) do
      {
        market_id: market_id,
        levels: 50,
        bids: [
          [100.0, 5.0, 'collection_bid_hash', merkle_root_hash, 1640995200],  # Collection买单
          [95.0, 3.0, 'specific_bid_hash', token_id_1, 1640995200]            # Specific买单
        ],
        asks: [
          [90.0, 2.0, 'compatible_ask_hash_1', token_id_1, 1640995200],      # 兼容两种买单
          [92.0, 1.0, 'compatible_ask_hash_2', token_id_2, 1640995200],      # 只兼容Collection买单
          [88.0, 1.0, 'incompatible_ask_hash', token_id_3, 1640995200],      # 不兼容任何买单
          [85.0, 4.0, 'collection_ask_hash', merkle_root_hash, 1640995200]   # Collection卖单
        ]
      }
    end
    
    before do
      allow_any_instance_of(MarketData::OrderBookDepth).to receive(:call).and_return(order_book_data)
      allow(Rails.logger).to receive(:info)
      allow(Rails.logger).to receive(:warn)
      allow(Rails.logger).to receive(:debug)
    end
    
    it '正确处理Collection-Specific混合匹配场景' do
      # group_orders_by_compatibility 返回兼容组
      groups = match_engine.group_orders_by_compatibility(
        order_book_data[:bids], order_book_data[:asks]
      )

      # 验证分组逻辑正确（Collection买单能匹配到兼容的卖单）
      collection_group = groups.find { |g| g[:type] == 'collection_to_mixed' }
      expect(collection_group).not_to be_nil
      expect(collection_group[:asks].size).to be >= 1
    end
  end
  
  describe '性能测试', integration: true do
    it 'Merkle树验证在合理时间内完成' do
      bids = Array.new(10) { |i| [100.0 - i, 1.0, "bid_#{i}", merkle_root_hash, 1640995200] }
      asks = Array.new(20) { |i| [90.0 + i, 1.0, "ask_#{i}", "1460#{i}", 1640995200] }

      start_time = Time.current
      result = match_engine.group_orders_by_compatibility(bids, asks)
      end_time = Time.current

      execution_time = end_time - start_time
      expect(execution_time).to be < 2.0  # 应该在2秒内完成
      expect(result).to be_an(Array)
    end
  end
  
  describe '边界条件和错误处理' do
    it '处理Merkle树查询异常' do
      allow(Rails.logger).to receive(:error)
      allow(Merkle::TreeRoot).to receive(:find_latest_active_by_root_hash).and_raise(StandardError.new("Database error"))
      
      result = match_engine.token_in_merkle_tree?(token_id_1, merkle_root_hash)
      
      expect(result).to be false
      expect(Rails.logger).to have_received(:error).with(/验证token_id.*时出错/)
    end
    
    it '处理空的订单簿数据' do
      groups = match_engine.group_orders_by_compatibility([], [])
      expect(groups).to be_empty
    end
    
    it '处理只有买单或只有卖单的情况' do
      bids = [[100.0, 5.0, 'bid_hash', merkle_root_hash, 1640995200]]
      
      groups = match_engine.group_orders_by_compatibility(bids, [])
      expect(groups).to be_empty
      
      groups = match_engine.group_orders_by_compatibility([], bids)
      expect(groups).to be_empty
    end
  end
end
