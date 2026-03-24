# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Orders::Events::AnalyticsTracker do
  let(:listener) { described_class.new }
  let(:market_id) { 'ETH-USD' }
  
  before do
    # Mock Redis.current
    allow(Redis).to receive(:current).and_return(redis_mock)
  end
  
  let(:redis_mock) do
    double('Redis').tap do |mock|
      allow(mock).to receive(:incrby)
      allow(mock).to receive(:incr)
      allow(mock).to receive(:hincrby)
      allow(mock).to receive(:hset)
      allow(mock).to receive(:zadd)
      allow(mock).to receive(:zremrangebyscore)
      allow(mock).to receive(:expire)
    end
  end
  
  describe '#order_fulfilled' do
    let(:event_data) do
      {
        event_id: 123,
        order_id: 456,
        market_id: market_id,
        transaction_hash: '0x123abc',
        fills_count: 2,
        timestamp: Time.current.to_i
      }
    end
    
    let(:event) { Infrastructure::EventBus::Event.new(name: 'order.fulfilled', data: event_data, metadata: {}) }
    
    it 'tracks market activity metrics' do
      expect(Rails.logger).to receive(:info).with(/Tracking order.fulfilled event/)
      
      listener.order_fulfilled(event)
      
      # 验证市场活跃度跟踪
      today_key = "analytics:market_activity:#{market_id}:#{Date.current.strftime('%Y%m%d')}"
      expect(redis_mock).to have_received(:incrby).with(today_key, 2)
      expect(redis_mock).to have_received(:expire).with(today_key, 7.days.to_i)
      
      # 验证小时级别统计
      hour_key = "analytics:market_activity:#{market_id}:#{Time.current.strftime('%Y%m%d%H')}"
      expect(redis_mock).to have_received(:incrby).with(hour_key, 2)
      expect(redis_mock).to have_received(:expire).with(hour_key, 3.days.to_i)
    end
    
    it 'tracks trading volume' do
      listener.order_fulfilled(event)
      
      volume_key = "analytics:trading_volume:#{market_id}"
      expect(redis_mock).to have_received(:zadd).with(volume_key, event_data[:timestamp], anything)
      expect(redis_mock).to have_received(:zremrangebyscore).with(volume_key, 0, anything)
    end
    
    it 'updates realtime stats' do
      listener.order_fulfilled(event)
      
      stats_key = "analytics:realtime_stats"
      expect(redis_mock).to have_received(:hincrby).with(stats_key, "total_fills_today", 2)
      expect(redis_mock).to have_received(:hincrby).with(stats_key, "total_orders_today", 1)
      expect(redis_mock).to have_received(:hset).with(stats_key, "last_activity", anything)
      expect(redis_mock).to have_received(:expire).with(stats_key, 1.day.to_i)
    end
  end
  
  describe '#order_status_updated' do
    let(:event_data) do
      {
        event_id: 123,
        order_id: 456,
        market_id: market_id,
        old_status: 'open',
        new_status: 'filled'
      }
    end
    
    let(:event) { Infrastructure::EventBus::Event.new(name: 'order.status_updated', data: event_data, metadata: {}) }
    
    it 'tracks status transitions' do
      expect(Rails.logger).to receive(:info).with(/Tracking order.status_updated/)
      
      listener.order_status_updated(event)
      
      transition_key = "analytics:status_transitions:#{Date.current.strftime('%Y%m%d')}"
      expect(redis_mock).to have_received(:hincrby).with(transition_key, "open_to_filled", 1)
      expect(redis_mock).to have_received(:expire).with(transition_key, 30.days.to_i)
    end
    
    it 'tracks order completion for filled orders' do
      listener.order_status_updated(event)
      
      completion_key = "analytics:completions:#{market_id}:#{Date.current.strftime('%Y%m%d')}"
      expect(redis_mock).to have_received(:incr).with(completion_key)
      expect(redis_mock).to have_received(:expire).with(completion_key, 30.days.to_i)
    end
    
    it 'does not track completion for non-filled orders' do
      event_data[:new_status] = 'cancelled'
      
      listener.order_status_updated(event)
      
      completion_key = "analytics:completions:#{market_id}:#{Date.current.strftime('%Y%m%d')}"
      expect(redis_mock).not_to have_received(:incr).with(completion_key)
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
    
    it 'tracks matching efficiency metrics' do
      expect(Rails.logger).to receive(:info).with(/Tracking order.matched event/)
      
      listener.order_matched(event)
      
      efficiency_key = "analytics:matching:#{Date.current.strftime('%Y%m%d')}"
      expect(redis_mock).to have_received(:hincrby).with(efficiency_key, "total_matches", 1)
      expect(redis_mock).to have_received(:hset).with(efficiency_key, "last_match_time", anything)
      expect(redis_mock).to have_received(:expire).with(efficiency_key, 30.days.to_i)
      
      daily_key = "analytics:daily_matches:#{Date.current.strftime('%Y%m%d')}"
      expect(redis_mock).to have_received(:incr).with(daily_key)
      expect(redis_mock).to have_received(:expire).with(daily_key, 90.days.to_i)
    end
  end
end
