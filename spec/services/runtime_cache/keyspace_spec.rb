# frozen_string_literal: true

require 'rails_helper'

RSpec.describe RuntimeCache::Keyspace do
  describe '.market_key' do
    it 'generates correct market key' do
      expect(described_class.market_key(123)).to eq("market:123")
    end
  end
  
  describe '.sub_count_key' do
    it 'generates correct subscription count key' do
      expect(described_class.sub_count_key("123@TICKER_1")).to eq("sub_count:123@TICKER_1")
    end
  end
  
  describe '.kline_key' do
    it 'generates correct kline key' do
      expect(described_class.kline_key(123, 60)).to eq("kline:123:60")
    end
  end
  
  describe '.trade_key' do
    it 'generates correct trade key' do
      expect(described_class.trade_key(123)).to eq("trade:123")
    end
  end
  
  describe '.depth_key' do
    it 'generates correct depth key with default limit' do
      expect(described_class.depth_key(123)).to eq("depth:123:20")
    end
    
    it 'generates correct depth key with custom limit' do
      expect(described_class.depth_key(123, 50)).to eq("depth:123:50")
    end
  end
  
  describe '.next_aligned_key' do
    it 'generates correct next aligned key' do
      expect(described_class.next_aligned_key("123@TICKER_1")).to eq("next_aligned_ts:123@TICKER_1")
    end
  end
  
  describe '.preclose_key' do
    it 'generates correct preclose key' do
      expect(described_class.preclose_key(123, 1609459200)).to eq("preclose:123:1609459200")
    end
  end
  
  describe '.batch_market_keys' do
    it 'generates multiple market keys' do
      market_ids = [123, 456, 789]
      expected_keys = ["market:123", "market:456", "market:789"]
      
      expect(described_class.batch_market_keys(market_ids)).to eq(expected_keys)
    end
  end
  
  describe '.parse_topic_from_sub_key' do
    it 'parses topic from subscription key' do
      sub_key = "sub_count:123@TICKER_1"
      expect(described_class.parse_topic_from_sub_key(sub_key)).to eq("123@TICKER_1")
    end
  end
  
  describe '.parse_market_id_from_key' do
    it 'parses market ID from market key' do
      market_key = "market:123"
      expect(described_class.parse_market_id_from_key(market_key)).to eq(123)
    end
    
    it 'parses market ID from kline key' do
      kline_key = "kline:456:60"
      expect(described_class.parse_market_id_from_key(kline_key)).to eq(456)
    end
  end
  
  describe '.find_keys' do
    before do
      allow(Redis.current).to receive(:keys).with("market:*").and_return(["market:123", "market:456"])
    end
    
    it 'finds keys by pattern' do
      result = described_class.find_keys("market:*")
      expect(result).to contain_exactly("market:123", "market:456")
    end
  end
  
  describe '.active_subscription_keys' do
    let(:all_sub_keys) { ["sub_count:123@TICKER_1", "sub_count:456@TICKER_1", "sub_count:789@TICKER_1"] }
    
    before do
      allow(Redis.current).to receive(:keys).with("sub_count:*").and_return(all_sub_keys)
      allow(Redis.current).to receive(:get).with("sub_count:123@TICKER_1").and_return("5")
      allow(Redis.current).to receive(:get).with("sub_count:456@TICKER_1").and_return("0")
      allow(Redis.current).to receive(:get).with("sub_count:789@TICKER_1").and_return("3")
    end
    
    it 'returns only keys with active subscriptions' do
      result = described_class.active_subscription_keys
      expect(result).to contain_exactly("sub_count:123@TICKER_1", "sub_count:789@TICKER_1")
    end
  end
  
  describe '.key_exists?' do
    it 'returns true when key exists' do
      allow(Redis.current).to receive(:exists).with("market:123").and_return(1)
      
      result = described_class.key_exists?("market:123")
      expect(result).to be true
    end
    
    it 'returns false when key does not exist' do
      allow(Redis.current).to receive(:exists).with("market:123").and_return(0)
      
      result = described_class.key_exists?("market:123")
      expect(result).to be false
    end
  end
  
  describe '.key_ttl' do
    it 'returns TTL for key' do
      allow(Redis.current).to receive(:ttl).with("market:123").and_return(3600)
      
      result = described_class.key_ttl("market:123")
      expect(result).to eq(3600)
    end
  end
  
  describe '.delete_keys' do
    it 'deletes multiple keys' do
      keys = ["market:123", "market:456"]
      expect(Redis.current).to receive(:del).with(*keys).and_return(2)
      
      result = described_class.delete_keys(keys)
      expect(result).to eq(2)
    end
    
    it 'returns 0 for empty array' do
      result = described_class.delete_keys([])
      expect(result).to eq(0)
    end
  end
  
  describe '.delete_keys_by_pattern' do
    before do
      allow(Redis.current).to receive(:keys).with("market:*").and_return(["market:123", "market:456"])
      allow(Redis.current).to receive(:del).with("market:123", "market:456").and_return(2)
    end
    
    it 'deletes keys matching pattern' do
      result = described_class.delete_keys_by_pattern("market:*")
      expect(result).to eq(2)
    end
  end
  
  describe '.default_ttl_for_key' do
    it 'returns correct TTL for market key' do
      expect(described_class.default_ttl_for_key("market:123")).to eq(described_class::DEFAULT_MARKET_TTL)
    end
    
    it 'returns correct TTL for kline key' do
      expect(described_class.default_ttl_for_key("kline:123:60")).to eq(described_class::DEFAULT_KLINE_TTL)
    end
    
    it 'returns correct TTL for trade key' do
      expect(described_class.default_ttl_for_key("trade:123")).to eq(described_class::DEFAULT_TRADE_TTL)
    end
    
    it 'returns correct TTL for depth key' do
      expect(described_class.default_ttl_for_key("depth:123:20")).to eq(described_class::DEFAULT_DEPTH_TTL)
    end
    
    it 'returns correct TTL for subscription key' do
      expect(described_class.default_ttl_for_key("sub_count:123@TICKER_1")).to eq(described_class::DEFAULT_SUB_COUNT_TTL)
    end
    
    it 'returns default TTL for unknown key' do
      expect(described_class.default_ttl_for_key("unknown:key")).to eq(3600)
    end
  end
end