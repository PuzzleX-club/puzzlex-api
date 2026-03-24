# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Orders::Events::MarketDataUpdater do
  let(:listener) { described_class.new }
  let(:market_id) { 'ETH-USD' }
  let(:order) { create(:trading_order, market_id: market_id) }

  before do
    # Mock Redis to prevent real connections
    redis_mock = double('Redis',
      get: nil, set: true, keys: [], sadd: true,
      smembers: [], expire: true, del: true,
      hget: nil, hset: true, hgetall: {}
    )
    allow(Redis).to receive(:current).and_return(redis_mock)

    # Mock model callbacks that hit Redis/Sidekiq
    allow_any_instance_of(Trading::OrderFill).to receive(:enqueue_trade_broadcast)
    allow_any_instance_of(Trading::OrderFill).to receive(:mark_market_changed)
    allow_any_instance_of(Trading::Order).to receive(:broadcast_depth_if_subscribed)
    allow_any_instance_of(Trading::Order).to receive(:mark_market_summary_dirty)

    # Mock Sidekiq workers
    allow(Jobs::Orders::DepthBroadcastJob).to receive(:perform_async)
    allow(Jobs::Matching::Worker).to receive(:perform_in)
    allow(Jobs::MarketData::Broadcast::TradeBatchJob).to receive(:perform_in)

    # Mock SubscriptionGuard to prevent Redis calls
    allow(Realtime::SubscriptionGuard).to receive(:depth_limits_for_market).and_return([])

    # Mock MarketData::FillEventRecorder
    allow(MarketData::FillEventRecorder).to receive(:record!)
  end

  describe '#order_fulfilled' do
    let(:event_data) do
      {
        event_id: 123,
        order_id: order.id,
        market_id: market_id,
        transaction_hash: '0x123abc',
        fills_count: 2,
        timestamp: Time.current.to_i
      }
    end
    
    let(:event) { Infrastructure::EventBus::Event.new(name: 'order.fulfilled', data: event_data, metadata: {}) }
    
    before do
      # Mock价格计算服务
      allow(MarketData::PriceCalculator).to receive(:calculate_price_from_fill).and_return(1500.0)
      
      # Mock Redis服务
      allow(RuntimeCache::MarketDataStore).to receive(:update_market_field)
      allow(RuntimeCache::MarketDataStore).to receive(:increment_market_field)
      allow(RuntimeCache::MarketDataStore).to receive(:get_trades).and_return([])
      allow(RuntimeCache::MarketDataStore).to receive(:store_trades)
      
      # Mock统一广播Worker
      allow(Jobs::MarketData::Broadcast::Worker).to receive(:perform_async)
      
      # Mock OrderFill的广播方法，避免Redis连接
      allow_any_instance_of(Trading::OrderFill).to receive(:enqueue_trade_broadcast)
    end
    
    it 'processes order fulfilled event' do
      # 创建测试填充记录
      fill = create(:trading_order_fill, 
                    order: order, 
                    market_id: market_id, 
                    filled_amount: 100.0)
      
      allow(Trading::OrderFill).to receive_message_chain(:where, :order, :first).and_return(fill)
      
      expect(Rails.logger).to receive(:info).with(/Processing order.fulfilled for market/)
      
      listener.order_fulfilled(event)
      
      # 验证市场数据更新
      expect(RuntimeCache::MarketDataStore).to have_received(:update_market_field)
        .with(market_id, "close", "1500.0")
      expect(RuntimeCache::MarketDataStore).to have_received(:increment_market_field)
        .with(market_id, "vol", 100.0)
        
      # 验证K线广播
      expect(Jobs::MarketData::Broadcast::Worker).to have_received(:perform_async)
        .with('kline_batch', hash_including(batch: [["#{market_id}@KLINE_60", anything]]))
    end
    
    it 'returns early if market_id is missing' do
      event_data[:market_id] = nil
      
      expect(Rails.logger).not_to receive(:info)
      
      listener.order_fulfilled(event)
    end
    
    it 'handles missing fill records gracefully' do
      allow(Trading::OrderFill).to receive_message_chain(:where, :order, :first).and_return(nil)
      
      expect { listener.order_fulfilled(event) }.not_to raise_error
      
      expect(RuntimeCache::MarketDataStore).not_to have_received(:update_market_field)
    end
  end
  
  describe '#order_status_updated' do
    let(:event_data) do
      {
        event_id: 123,
        order_id: order.id,
        market_id: market_id,
        old_status: 'open',
        new_status: 'filled'
      }
    end
    
    let(:event) { Infrastructure::EventBus::Event.new(name: 'order.status_updated', data: event_data, metadata: {}) }
    
    before do
      allow(Jobs::MarketData::Broadcast::Worker).to receive(:perform_async)
    end
    
    it 'triggers depth update for filled orders' do
      expect(Rails.logger).to receive(:info).with(/Processing order.status_updated/)
      
      listener.order_status_updated(event)
      
      expect(Jobs::MarketData::Broadcast::Worker).to have_received(:perform_async)
        .with('depth', hash_including(market_id: market_id, limit: 20))
    end
    
    it 'triggers depth update for cancelled orders' do
      event_data[:new_status] = 'cancelled'
      
      listener.order_status_updated(event)
      
      expect(Jobs::MarketData::Broadcast::Worker).to have_received(:perform_async)
        .with('depth', hash_including(market_id: market_id))
    end
    
    it 'does not trigger depth update for other statuses' do
      event_data[:new_status] = 'pending'
      
      listener.order_status_updated(event)
      
      expect(Jobs::MarketData::Broadcast::Worker).not_to have_received(:perform_async)
    end
  end
  
  describe '#order_matched' do
    let(:event_data) do
      {
        event_id: 123,
        transaction_hash: '0x123abc',
        matched_orders: ['0xabc', '0xdef']
      }
    end
    
    let(:event) { Infrastructure::EventBus::Event.new(name: 'order.matched', data: event_data, metadata: {}) }
    
    it 'logs the matched event' do
      expect(Rails.logger).to receive(:info).with(/Processing order.matched event/)
      
      listener.order_matched(event)
    end
  end
end
