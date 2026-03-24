# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Jobs::MarketData::Generation::KlineJob, type: :job do
  include ServiceTestHelpers

  before do
    stub_redis
    stub_action_cable
    stub_sidekiq_workers
  end

  describe '#perform' do
    context 'with target_market_ids (slice mode)' do
      let!(:market1) { create(:market, market_id: 101) }
      let!(:market2) { create(:market, market_id: 102) }
      let(:persister_double) { double('KlinePersister', complete_kline_data: 5) }

      before do
        allow(MarketData::KlinePersister).to receive(:new).and_return(persister_double)
      end

      it 'executes for specified markets' do
        expect(MarketData::KlinePersister).to receive(:new).at_least(:once)

        subject.perform([101, 102])
      end

      it 'processes all intervals for each market' do
        # 6 intervals * 2 markets = 12 calls
        expect(MarketData::KlinePersister).to receive(:new).exactly(12).times

        subject.perform([101, 102])
      end

      it 'handles errors gracefully' do
        allow(persister_double).to receive(:complete_kline_data).and_raise(StandardError, 'Test error')

        expect {
          subject.perform([101])
        }.not_to raise_error
      end
    end

    context 'without target_market_ids (dispatch mode)' do
      let!(:market1) { create(:market, market_id: 201) }
      let!(:market2) { create(:market, market_id: 202) }
      let(:dispatcher_class) { class_double('Sidekiq::Sharding::Dispatcher').as_stubbed_const }
      let(:dispatcher_double) { double('ShardingDispatcher', dispatch_batch: nil, active_instance_count: 2) }

      context 'when instance is leader' do
        before do
          allow(Sidekiq::Election::Service).to receive(:leader?).and_return(true)
          allow(dispatcher_class).to receive(:new).and_return(dispatcher_double)
        end

        it 'dispatches markets to sharded queues' do
          expect(dispatcher_double).to receive(:dispatch_batch)

          subject.perform
        end
      end

      context 'when instance is not leader' do
        before do
          allow(Sidekiq::Election::Service).to receive(:leader?).and_return(false)
        end

        it 'skips dispatching' do
          expect(dispatcher_class).not_to receive(:new)

          subject.perform
        end
      end

      context 'when election service raises error' do
        before do
          allow(Sidekiq::Election::Service).to receive(:leader?).and_raise(StandardError, 'Election error')
        end

        it 'handles error and returns early' do
          expect {
            subject.perform
          }.not_to raise_error
        end
      end
    end
  end

  describe 'sidekiq configuration' do
    it 'uses scheduler queue' do
      expect(described_class.sidekiq_options['queue'].to_s).to eq('scheduler')
    end

    it 'has retry set to 2' do
      expect(described_class.sidekiq_options['retry']).to eq(2)
    end
  end

  describe 'INTERVALS_IN_MINUTES constant' do
    it 'contains expected intervals' do
      expected = [30, 60, 360, 720, 1440, 10080]

      expect(described_class::INTERVALS_IN_MINUTES).to eq(expected)
    end
  end
end
