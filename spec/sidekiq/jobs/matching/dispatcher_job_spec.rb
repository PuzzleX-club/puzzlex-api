# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Jobs::Matching::DispatcherJob, type: :job do
  include ServiceTestHelpers

  let(:redis_mock) { stub_redis }
  let(:dispatcher) do
    double('ShardingDispatcher',
      dispatch: true,
      active_instance_count: 1
    )
  end
  let(:pre_validator) do
    instance_double(Matching::State::OrderPreValidator,
      validate: { valid: true, reason: nil, details: {} }
    )
  end

  before do
    stub_action_cable
    stub_sidekiq_workers

    # Ensure Sidekiq.redis yields the same mock as stub_redis
    allow(Sidekiq).to receive(:redis).and_yield(redis_mock)

    # Implementation uses Sidekiq::Sharding::Dispatcher (autoloaded at runtime)
    dispatcher_class = class_double('Sidekiq::Sharding::Dispatcher').as_stubbed_const
    allow(dispatcher_class).to receive(:new).and_return(dispatcher)

    # Stub OrderPreValidator to avoid real validation
    allow(Matching::State::OrderPreValidator).to receive(:new).and_return(pre_validator)
  end

  describe '#perform' do
    context 'when leader' do
      before do
        allow(Sidekiq::Election::Service).to receive(:leader?).and_return(true)
        allow(redis_mock).to receive(:get).with('orderMatcherInitialized').and_return('1')
        allow(redis_mock).to receive(:smembers).with('market_list').and_return([])
      end

      context 'when markets exist' do
        let(:market_id) { '2800' }

        before do
          allow(redis_mock).to receive(:smembers).with('market_list').and_return([market_id])
          allow(redis_mock).to receive(:exists).with("orderMatcher:#{market_id}").and_return(1)
          allow(redis_mock).to receive(:hget).with("orderMatcher:#{market_id}", 'status').and_return('waiting')
        end

        it 'dispatches markets in waiting status' do
          expect(dispatcher).to receive(:dispatch)
            .with(Jobs::Matching::Worker, market_id, 'scheduled')

          subject.perform
        end
      end

      context 'when queue is empty' do
        before do
          allow(redis_mock).to receive(:smembers).with('market_list').and_return([])
        end

        it 'does nothing' do
          expect(dispatcher).not_to receive(:dispatch)
          subject.perform
        end
      end

      context 'when market has confirming status with filled orders' do
        let(:market_id) { '2800' }

        before do
          allow(redis_mock).to receive(:smembers).with('market_list').and_return([market_id])
          allow(redis_mock).to receive(:exists).with("orderMatcher:#{market_id}").and_return(1)
          allow(redis_mock).to receive(:hget).with("orderMatcher:#{market_id}", 'status').and_return('confirming')
          allow(redis_mock).to receive(:hget).with("orderMatcher:#{market_id}", 'orders_hash').and_return(['0xabc123'].to_json)
        end

        it 'resets to waiting if all orders are filled' do
          create(:trading_order,
            order_hash: '0xabc123',
            market_id: market_id,
            onchain_status: 'filled'
          )

          expect(redis_mock).to receive(:hset).with("orderMatcher:#{market_id}", 'status', 'waiting')

          subject.perform
        end
      end
    end

    context 'when not leader' do
      before do
        allow(Sidekiq::Election::Service).to receive(:leader?).and_return(false)
      end

      it 'skips execution' do
        expect(redis_mock).not_to receive(:smembers)
        subject.perform
      end
    end

    context 'with election service error' do
      before do
        allow(Sidekiq::Election::Service).to receive(:leader?).and_raise(StandardError, 'Election error')
      end

      it 'handles error gracefully' do
        expect { subject.perform }.not_to raise_error
      end
    end
  end

  describe 'sidekiq configuration' do
    it 'uses the scheduler queue' do
      expect(described_class.sidekiq_options['queue'].to_s).to eq('scheduler')
    end

    it 'has retry set to 2' do
      expect(described_class.sidekiq_options['retry']).to eq(2)
    end
  end
end
