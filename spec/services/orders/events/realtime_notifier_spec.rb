# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Orders::Events::RealtimeNotifier do
  let(:listener) { described_class.new }
  let(:market_id) { 'ETH-USD' }
  
  before do
    # Mock统一广播Worker
    allow(Jobs::MarketData::Broadcast::Worker).to receive(:perform_async)
    allow(Jobs::MarketData::Generation::MarketAggregateJob).to receive(:perform_async)
    allow(Jobs::MarketData::Broadcast::MarketSnapshotJob).to receive(:perform_in)
  end
  
  describe '#order_fulfilled' do
    let(:event_data) do
      {
        event_id: 123,
        order_id: 456,
        market_id: market_id,
        transaction_hash: '0x123abc',
        fills_count: 2
      }
    end
    
    let(:event) { Infrastructure::EventBus::Event.new(name: 'order.fulfilled', data: event_data, metadata: {}) }
    
    it 'broadcasts multiple update types' do
      expect(Rails.logger).to receive(:info).with(/Broadcasting updates for order.fulfilled/)
      
      listener.order_fulfilled(event)
      
      # 验证ticker广播
      expect(Jobs::MarketData::Generation::MarketAggregateJob).to have_received(:perform_async)
        .with([market_id])
      expect(Jobs::MarketData::Broadcast::MarketSnapshotJob).to have_received(:perform_in)
        .with(5.seconds)
      
      # 验证市场实时广播
      expect(Jobs::MarketData::Broadcast::Worker).to have_received(:perform_async)
        .with('market_realtime', hash_including(topic: 'MARKET@realtime'))
    end
    
    it 'returns early if market_id is missing' do
      event_data[:market_id] = nil
      
      expect(Rails.logger).not_to receive(:info)
      
      listener.order_fulfilled(event)
      
      expect(Jobs::MarketData::Broadcast::Worker).not_to have_received(:perform_async)
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
    
    it 'broadcasts depth update for status changes that affect order book' do
      expect(Rails.logger).to receive(:info).with(/Broadcasting status update/)
      
      listener.order_status_updated(event)
      
      expect(Jobs::MarketData::Broadcast::Worker).to have_received(:perform_async)
        .with('depth', hash_including(market_id: market_id, limit: 20))
    end
    
    it 'broadcasts depth update for cancelled orders' do
      event_data[:new_status] = 'cancelled'
      
      listener.order_status_updated(event)
      
      expect(Jobs::MarketData::Broadcast::Worker).to have_received(:perform_async)
        .with('depth', hash_including(market_id: market_id))
    end
    
    it 'broadcasts depth update for partially filled orders' do
      event_data[:new_status] = 'partially_filled'
      
      listener.order_status_updated(event)
      
      expect(Jobs::MarketData::Broadcast::Worker).to have_received(:perform_async)
        .with('depth', hash_including(market_id: market_id))
    end
    
    it 'does not broadcast for other status changes' do
      event_data[:new_status] = 'pending'
      
      listener.order_status_updated(event)
      
      expect(Jobs::MarketData::Broadcast::Worker).not_to have_received(:perform_async)
    end
    
    it 'returns early if market_id is missing' do
      event_data[:market_id] = nil
      
      expect(Rails.logger).not_to receive(:info)
      
      listener.order_status_updated(event)
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
    
    it 'broadcasts market realtime update' do
      expect(Rails.logger).to receive(:info).with(/Broadcasting order match notification/)
      
      listener.order_matched(event)
      
      expect(Jobs::MarketData::Broadcast::Worker).to have_received(:perform_async)
        .with('market_realtime', hash_including(topic: 'MARKET@realtime'))
    end
  end
end
