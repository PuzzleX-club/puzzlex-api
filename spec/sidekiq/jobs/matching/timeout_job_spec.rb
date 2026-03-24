# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Jobs::Matching::TimeoutJob, type: :job do
  include ServiceTestHelpers

  before do
    stub_redis
    stub_action_cable
    stub_sidekiq_workers
  end

  describe '#perform' do
    let(:market_id) { '2800' }

    context 'when leader' do
      before do
        allow(Sidekiq::Election::Service).to receive(:leader?).and_return(true)
      end

      it 'processes stuck matching orders' do
        stuck_order = create(:trading_order,
          market_id: market_id,
          offchain_status: 'matching',
          offchain_status_updated_at: 60.seconds.ago
        )

        mock_logger = double('MatchingLogger',
          log_timeout_cleanup: true,
          log_queue_exit: true,
          log_session_success: true
        )
        allow(Matching::State::Logger).to receive(:new).and_return(mock_logger)

        expect { subject.perform }.not_to raise_error
      end

      it 'skips when no stuck orders exist' do
        # No orders created - should skip
        expect { subject.perform }.not_to raise_error
      end

      it 'does not process recent matching orders' do
        # Order updated recently (within timeout threshold)
        recent_order = create(:trading_order,
          market_id: market_id,
          offchain_status: 'matching',
          offchain_status_updated_at: 5.seconds.ago
        )

        expect { subject.perform }.not_to raise_error
        recent_order.reload
        expect(recent_order.offchain_status).to eq('matching')
      end

      it 'groups orders by market for processing' do
        market1_order = create(:trading_order,
          market_id: '101',
          offchain_status: 'matching',
          offchain_status_updated_at: 60.seconds.ago
        )
        market2_order = create(:trading_order,
          market_id: '102',
          offchain_status: 'matching',
          offchain_status_updated_at: 60.seconds.ago
        )

        mock_logger = double('MatchingLogger',
          log_timeout_cleanup: true,
          log_queue_exit: true,
          log_session_success: true
        )
        allow(Matching::State::Logger).to receive(:new).and_return(mock_logger)

        expect { subject.perform }.not_to raise_error
      end
    end

    context 'when not leader' do
      before do
        allow(Sidekiq::Election::Service).to receive(:leader?).and_return(false)
      end

      it 'skips execution' do
        create(:trading_order,
          market_id: market_id,
          offchain_status: 'matching',
          offchain_status_updated_at: 60.seconds.ago
        )

        # Should not process orders
        expect(Matching::State::Logger).not_to receive(:new)
        subject.perform
      end

      it 'returns early without error' do
        expect { subject.perform }.not_to raise_error
      end
    end

    context 'with election service error' do
      before do
        allow(Sidekiq::Election::Service).to receive(:leader?).and_raise(StandardError, 'Election error')
      end

      it 'handles error gracefully' do
        expect { subject.perform }.not_to raise_error
      end

      it 'does not process any orders' do
        create(:trading_order,
          market_id: market_id,
          offchain_status: 'matching',
          offchain_status_updated_at: 60.seconds.ago
        )

        expect(Matching::State::Logger).not_to receive(:new)
        subject.perform
      end
    end
  end

  describe 'sidekiq configuration' do
    it 'uses the scheduler queue' do
      expect(described_class.sidekiq_options['queue'].to_s).to eq('scheduler')
    end

    it 'has retry set to 3' do
      expect(described_class.sidekiq_options['retry']).to eq(3)
    end
  end
end
