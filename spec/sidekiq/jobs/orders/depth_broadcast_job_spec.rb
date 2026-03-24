# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Jobs::Orders::DepthBroadcastJob, type: :job do
  include ServiceTestHelpers

  before do
    stub_redis
    stub_action_cable
    stub_sidekiq_workers
  end

  describe '#perform' do
    let(:market_id) { '101' }
    let(:mock_depth_data) do
      {
        bids: [['100', '10'], ['99', '20']],
        asks: [['101', '15'], ['102', '25']],
        market_id: market_id,
        levels: 5
      }
    end

    context 'when market_id is blank' do
      it 'returns early without processing' do
        expect(Redis.current).not_to receive(:keys)

        subject.perform(nil)
      end

      it 'returns early for empty string' do
        expect(Redis.current).not_to receive(:keys)

        subject.perform('')
      end
    end

    context 'when no subscribers' do
      before do
        allow(Realtime::SubscriptionGuard).to receive(:depth_limits_for_market)
          .with(market_id).and_return([])
      end

      it 'returns early without fetching depth data' do
        expect(MarketData::OrderBookDepth).not_to receive(:new)

        subject.perform(market_id)
      end
    end

    context 'when there are subscribers' do
      before do
        allow(Realtime::SubscriptionGuard).to receive(:depth_limits_for_market)
          .with(market_id).and_return([5, 10])
        allow_any_instance_of(MarketData::OrderBookDepth).to receive(:call).and_return(mock_depth_data)
      end

      it 'fetches depth data for max limit' do
        expect(MarketData::OrderBookDepth).to receive(:new)
          .with(market_id, 10, validate_criteria: true)
          .and_call_original

        subject.perform(market_id)
      end

      it 'broadcasts to ActionCable for each limit' do
        expect(ActionCable.server).to receive(:broadcast)
          .with("#{market_id}@DEPTH_5", hash_including(:topic, :data))
        expect(ActionCable.server).to receive(:broadcast)
          .with("#{market_id}@DEPTH_10", hash_including(:topic, :data))

        subject.perform(market_id)
      end

      it 'includes correct data in broadcast' do
        expect(ActionCable.server).to receive(:broadcast) do |_topic, payload|
          expect(payload[:data]).to include(:market_id, :symbol, :levels, :bids, :asks, :ts)
        end.at_least(:once)

        subject.perform(market_id)
      end
    end

    context 'when subscriber count is zero' do
      before do
        allow(Realtime::SubscriptionGuard).to receive(:depth_limits_for_market)
          .with(market_id).and_return([])
      end

      it 'skips broadcasting' do
        expect(MarketData::OrderBookDepth).not_to receive(:new)

        subject.perform(market_id)
      end
    end
  end

  describe 'sidekiq configuration' do
    it 'uses default queue' do
      expect(described_class.sidekiq_options['queue'].to_s).to eq('default')
    end

    it 'has retry disabled' do
      expect(described_class.sidekiq_options['retry']).to eq(false)
    end
  end
end
