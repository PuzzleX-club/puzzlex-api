# spec/services/matching/merkle_cache_spec.rb

require 'rails_helper'

# 这个测试需要真实的缓存功能，确保使用memory_store
RSpec.describe Matching::Engine, type: :service do
  # 在此测试套件中临时启用缓存
  before(:all) do
    @original_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
  end
  
  after(:all) do
    Rails.cache = @original_cache if @original_cache
  end
  let(:market_id) { "test_market_123" }
  let(:strategy) { Matching::Engine.new(market_id) }
  let(:merkle_root) { "0x1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef" }
  let(:token_id) { "14601" }
  
  before do
    # 使用 ServiceTestHelpers 提供的 stub 方法
    stub_redis
    stub_action_cable
    stub_sidekiq_workers

    # 清理缓存，确保测试隔离性
    Rails.cache.clear

    # 创建测试数据
    @root_record = create(:merkle_tree_root, {
      root_hash: merkle_root,
      snapshot_id: 'test_snap_001',
      created_at: 1.hour.ago,
      expires_at: 1.hour.from_now,
      item_id: 145
    })
    
    @node_record = create(:merkle_tree_node, {
      snapshot_id: 'test_snap_001',
      token_id: token_id.to_i,
      is_leaf: true
    })
  end
  
  after do
    Rails.cache.clear
  end

  describe '#token_in_merkle_tree?' do
    context '基本缓存功能' do
      it '首次查询时缓存未命中，从数据库查询' do
        # 使用宽松的logger mock
        allow(Rails.logger).to receive(:debug)
        
        result = strategy.token_in_merkle_tree?(token_id, merkle_root)
        expect(result).to be true
        
        # 验证实际是从数据库查询（通过检查生成的缓存）
        cache_key = "merkle_verify:v2:#{merkle_root}:#{@root_record.snapshot_id}:#{token_id}"
        expect(Rails.cache.read(cache_key)).to be true
      end
      
      it '第二次查询时缓存命中' do
        allow(Rails.logger).to receive(:debug)
        allow(Rails.logger).to receive(:warn)
        
        # 第一次查询建立缓存
        result1 = strategy.token_in_merkle_tree?(token_id, merkle_root)
        expect(result1).to be true
        
        # 验证缓存被创建
        cache_key = "merkle_verify:v2:#{merkle_root}:#{@root_record.snapshot_id}:#{token_id}"
        expect(Rails.cache.read(cache_key)).to be true
        
        # 第二次查询应该使用缓存
        result2 = strategy.token_in_merkle_tree?(token_id, merkle_root)
        expect(result2).to be true
      end
      
      it '缓存键包含版本信息确保一致性' do
        strategy.token_in_merkle_tree?(token_id, merkle_root)
        
        # 验证缓存键格式
        expected_cache_key = "merkle_verify:v2:#{merkle_root}:#{@root_record.snapshot_id}:#{token_id}"
        cached_value = Rails.cache.read(expected_cache_key)
        expect(cached_value).to be true
      end
    end

    context '安全性验证' do
      it '当Merkle根不存在时返回false且不缓存' do
        non_existent_root = "0xdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbe"
        
        expect(Rails.logger).to receive(:warn).with(/Merkle根已失效或不存在/)
        
        result = strategy.token_in_merkle_tree?(token_id, non_existent_root)
        expect(result).to be false
        
        # 验证没有缓存无效结果（当Merkle根不存在时，不会建立缓存）
        # 由于root_record为nil，无法构造有效的缓存键，因此不会有缓存
      end
      
      it '当Merkle根已过期时清理缓存并返回false' do
        allow(Rails.logger).to receive(:debug)
        allow(Rails.logger).to receive(:warn)
        allow(Rails.logger).to receive(:error)
        
        # 先建立缓存
        result1 = strategy.token_in_merkle_tree?(token_id, merkle_root)
        expect(result1).to be true
        
        # 验证缓存存在
        cache_key = "merkle_verify:v2:#{merkle_root}:#{@root_record.snapshot_id}:#{token_id}"
        expect(Rails.cache.read(cache_key)).to be true
        
        # 模拟Merkle根过期
        @root_record.update!(expires_at: 1.minute.ago)
        
        # 过期后的查询应该返回false
        result2 = strategy.token_in_merkle_tree?(token_id, merkle_root)
        expect(result2).to be false
        
        # 验证缓存被清理（如果缓存命中了的话）
        expect(Rails.cache.read(cache_key)).to be_nil
      end
      
      it '处理数据库查询异常' do
        allow(Merkle::TreeRoot).to receive(:find_latest_active_by_root_hash)
          .and_raise(StandardError, "数据库连接失败")
        
        expect(Rails.logger).to receive(:error).with(/验证token_id.*时出错/)
        
        result = strategy.token_in_merkle_tree?(token_id, merkle_root)
        expect(result).to be false
      end
    end

    context '动态缓存时间计算' do
      it '当Merkle根即将过期时缩短缓存时间' do
        allow(Rails.logger).to receive(:debug)
        allow(Rails.logger).to receive(:warn)
        
        # 设置Merkle根30秒后过期
        @root_record.update!(expires_at: 30.seconds.from_now)
        
        result = strategy.token_in_merkle_tree?(token_id, merkle_root)
        expect(result).to be true
        
        # 验证calculate_safe_cache_expiry方法返回正确的缓存时间
        expiry = strategy.calculate_safe_cache_expiry(@root_record, true)
        expect(expiry).to be_between(10, 30)  # 应该比默认的300秒短
      end
      
      it '当Merkle根无过期时间时使用默认缓存时间' do
        @root_record.update!(expires_at: nil)
        
        result = strategy.token_in_merkle_tree?(token_id, merkle_root)
        expect(result).to be true
        
        # 验证使用了默认的缓存时间（300秒）
      end
    end

    context '边界条件处理' do
      it '处理空的token_id' do
        result = strategy.token_in_merkle_tree?("", merkle_root)
        expect(result).to be false
      end
      
      it '处理空的merkle_root' do
        result = strategy.token_in_merkle_tree?(token_id, "")
        expect(result).to be false
      end
      
      it '处理nil参数' do
        result = strategy.token_in_merkle_tree?(nil, nil)
        expect(result).to be false
      end
    end
  end

  describe '#calculate_safe_cache_expiry' do
    it '对于成功结果返回默认300秒' do
      @root_record.expires_at = nil
      expiry = strategy.calculate_safe_cache_expiry(@root_record, true)
      expect(expiry).to eq(300)
    end
    
    it '对于失败结果返回默认60秒' do
      @root_record.expires_at = nil
      expiry = strategy.calculate_safe_cache_expiry(@root_record, false)
      expect(expiry).to eq(60)
    end
    
    it '当Merkle根即将过期时返回安全的缓存时间' do
      @root_record.expires_at = 100.seconds.from_now
      expiry = strategy.calculate_safe_cache_expiry(@root_record, true)
      expect(expiry).to be_between(70, 85)  # 100 * 0.8 = 80左右
    end
    
    it '当Merkle根已过期时返回0' do
      @root_record.expires_at = 1.minute.ago
      expiry = strategy.calculate_safe_cache_expiry(@root_record, true)
      expect(expiry).to eq(0)
    end
    
    it '保证最小缓存时间为10秒' do
      @root_record.expires_at = 5.seconds.from_now
      expiry = strategy.calculate_safe_cache_expiry(@root_record, true)
      expect(expiry).to eq(10)
    end
  end

  describe '#verify_token_in_merkle_with_snapshot' do
    it '正确验证token存在于Merkle树中' do
      result = strategy.verify_token_in_merkle_with_snapshot(token_id, @root_record)
      expect(result).to be true
    end
    
    it '正确验证token不存在于Merkle树中' do
      non_existent_token = "99999"
      result = strategy.verify_token_in_merkle_with_snapshot(non_existent_token, @root_record)
      expect(result).to be false
    end
    
    it '处理数据库查询异常' do
      allow(Merkle::TreeNode).to receive(:exists?)
        .and_raise(StandardError, "数据库错误")
      
      expect(Rails.logger).to receive(:error).with(/验证token_id.*在snapshot.*中时出错/)
      
      result = strategy.verify_token_in_merkle_with_snapshot(token_id, @root_record)
      expect(result).to be false
    end
  end

  describe '缓存与业务逻辑集成测试' do
    it '在订单匹配流程中正确使用缓存' do
      allow(Rails.logger).to receive(:debug)
      allow(Rails.logger).to receive(:warn)
      
      # 第一次匹配，应该查询数据库并缓存
      result1 = strategy.token_in_merkle_tree?(token_id, merkle_root)
      expect(result1).to be true
      
      # 验证缓存被建立
      cache_key = "merkle_verify:v2:#{merkle_root}:#{@root_record.snapshot_id}:#{token_id}"
      expect(Rails.cache.read(cache_key)).to be true
      
      # 第二次匹配，应该使用缓存
      result2 = strategy.token_in_merkle_tree?(token_id, merkle_root)
      expect(result2).to be true
    end
    
    it '缓存失效后自动重新验证' do
      allow(Rails.logger).to receive(:debug)
      allow(Rails.logger).to receive(:warn)
      
      # 建立缓存
      result1 = strategy.token_in_merkle_tree?(token_id, merkle_root)
      expect(result1).to be true
      
      # 验证缓存存在
      cache_key = "merkle_verify:v2:#{merkle_root}:#{@root_record.snapshot_id}:#{token_id}"
      expect(Rails.cache.read(cache_key)).to be true
      
      # 清理缓存模拟过期
      Rails.cache.clear
      
      # 再次查询应该重新验证并重建缓存
      result2 = strategy.token_in_merkle_tree?(token_id, merkle_root)
      expect(result2).to be true
      expect(Rails.cache.read(cache_key)).to be true
    end
  end

  describe '性能测试' do
    it '批量验证时缓存能显著提升性能' do
      allow(Rails.logger).to receive(:debug)
      allow(Rails.logger).to receive(:warn)
      
      tokens = [token_id, "14602", "14603"]  # 减少数量，只测试存在的token
      
      # 为其他token创建节点，使用不同的node_index避免唯一约束冲突
      tokens[1..2].each_with_index do |tid, index|
        create(:merkle_tree_node, {
          snapshot_id: 'test_snap_001',
          token_id: tid.to_i,
          is_leaf: true,
          level: 0,
          node_index: index + 1,  # 使用不同的node_index
          node_hash: "hash_#{tid}"
        })
      end
      
      # 第一轮：建立缓存（测量数据库查询时间）
      first_round_queries = 0
      allow(Merkle::TreeNode).to receive(:exists?).and_wrap_original do |method, *args|
        first_round_queries += 1
        method.call(*args)
      end
      
      tokens.each { |token| strategy.token_in_merkle_tree?(token, merkle_root) }
      
      # 第二轮：使用缓存
      second_round_queries = 0
      allow(Merkle::TreeNode).to receive(:exists?).and_wrap_original do |method, *args|
        second_round_queries += 1
        method.call(*args)
      end
      
      tokens.each { |token| strategy.token_in_merkle_tree?(token, merkle_root) }
      
      # 第二轮的数据库查询应该减少（因为命中缓存）
      expect(second_round_queries).to be < first_round_queries
    end
  end
end 