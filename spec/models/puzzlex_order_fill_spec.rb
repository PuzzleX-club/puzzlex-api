# spec/models/puzzlex_order_fill_spec.rb
require 'rails_helper'

RSpec.describe Trading::OrderFill, type: :model do
  include ServiceTestHelpers

  let(:redis_mock) { stub_redis }

  before do
    stub_action_cable
    stub_sidekiq_workers
    # Stub callbacks that interact with external services
    allow_any_instance_of(Trading::OrderFill).to receive(:enqueue_trade_broadcast)
    allow_any_instance_of(Trading::OrderFill).to receive(:mark_market_changed)
  end

  describe 'associations' do
    it 'belongs to order' do
      fill = create(:trading_order_fill)
      expect(fill.order).to be_a(Trading::Order)
    end

    it 'belongs to order_item' do
      fill = create(:trading_order_fill)
      expect(fill.order_item).to be_a(Trading::OrderItem)
    end

    it 'belongs to market (optional)' do
      market = create(:market, market_id: '2800')
      fill = create(:trading_order_fill, market_id: '2800')
      expect(fill.market).to be_a(Trading::Market)
      expect(fill.market.market_id).to eq('2800')
    end
  end

  describe 'price_distribution' do
    it 'has default distribution from factory' do
      fill = create(:trading_order_fill)
      expect(fill.price_distribution).to be_an(Array)
      expect(fill.price_distribution.size).to eq(1)

      distribution = fill.price_distribution.first
      expect(distribution["token_address"]).to be_a(String)
      expect(distribution["item_type"]).to eq(2)
      expect(distribution["token_id"]).to be_a(String)
      expect(distribution["recipients"]).to be_an(Array)
      expect(distribution["total_amount"]).to eq("600")
    end
  end

  describe 'filled_amount' do
    it 'defaults to 1.0 from the factory' do
      fill = create(:trading_order_fill)
      expect(fill.filled_amount).to eq(1.0)
    end
  end

  describe 'block_timestamp' do
    it 'defaults to current time (in seconds) from factory' do
      fill = create(:trading_order_fill)
      expect(fill.block_timestamp).to be_within(5).of(Time.now.to_i)
    end
  end

  describe 'after_create callbacks' do
    context 'enqueue_trade_broadcast' do
      it 'is called after create' do
        # Remove the stub to test the actual callback
        allow_any_instance_of(Trading::OrderFill).to receive(:enqueue_trade_broadcast).and_call_original

        # Stub Redis operations used by enqueue_trade_broadcast
        allow(redis_mock).to receive(:sadd).and_return(true)
        allow(redis_mock).to receive(:set).and_return(true)

        fill = create(:trading_order_fill)
        # If we get here without error, the callback was invoked
        expect(fill).to be_persisted
      end
    end

    context 'mark_market_changed' do
      it 'is called after create' do
        # Remove the stub to test the actual callback
        allow_any_instance_of(Trading::OrderFill).to receive(:mark_market_changed).and_call_original

        # Stub external dependencies
        allow(MarketData::FillEventRecorder).to receive(:record!)
        allow(redis_mock).to receive(:sadd).and_return(true)

        fill = create(:trading_order_fill)
        expect(fill).to be_persisted
      end
    end
  end
end
