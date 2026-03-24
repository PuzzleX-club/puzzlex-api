# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Jobs::Matching::RecoveryJob, type: :job do
  include ServiceTestHelpers

  let(:redis_mock) { stub_redis }
  let(:market_id) { '2800' }

  before do
    stub_action_cable
    stub_sidekiq_workers
  end

  describe '#perform' do
    context 'when leader' do
      before do
        allow(Sidekiq::Election::Service).to receive(:leader?).and_return(true)
      end

      context 'with paused orders' do
        it 'recovers paused orders to active' do
          order = create(:trading_order,
            order_hash: '0xdef456',
            market_id: market_id,
            offchain_status: 'paused',
            offchain_status_reason: 'matching_timeout',
            offchain_status_updated_at: 2.minutes.ago
          )

          mock_logger = double('MatchingLogger',
            log_recovery_attempt: true,
            log_session_success: true,
            log_session_cancelled: true
          )
          allow(Matching::State::Logger).to receive(:new).and_return(mock_logger)

          contract_service = double('ContractService',
            get_order_status: { is_validated: true, is_cancelled: false, total_filled: 0, total_size: 100 }
          )
          allow(Seaport::ContractService).to receive(:new).and_return(contract_service)

          # Mock Matching::OverMatch::Detection methods for balance check
          allow(Matching::OverMatch::Detection).to receive(:send).and_return(true)

          subject.perform
          order.reload
          expect(order.offchain_status).to eq('active')
        end
      end

      context 'without paused orders' do
        it 'returns early' do
          expect { subject.perform }.not_to raise_error
        end
      end
    end

    context 'when not leader' do
      before do
        allow(Sidekiq::Election::Service).to receive(:leader?).and_return(false)
      end

      it 'skips execution' do
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
    it 'uses the critical queue' do
      expect(described_class.sidekiq_options['queue'].to_s).to eq('critical')
    end

    it 'has retry set to 3' do
      expect(described_class.sidekiq_options['retry']).to eq(3)
    end
  end
end
