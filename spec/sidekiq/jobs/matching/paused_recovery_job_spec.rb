# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Jobs::Matching::PausedRecoveryJob, type: :job do
  include ServiceTestHelpers

  let(:redis_mock) { stub_redis }
  let(:market_id) { '2800' }

  before do
    stub_action_cable
    stub_sidekiq_workers
    # The implementation uses Sidekiq.redis { |conn| ... }, not Redis.current
    allow(Sidekiq).to receive(:redis).and_yield(redis_mock)
  end

  describe '#perform' do
    context 'when leader' do
      before do
        allow(Sidekiq::Election::Service).to receive(:leader?).and_return(true)
      end

      it 'scans for paused orders older than threshold' do
        paused_order = create(:trading_order,
          market_id: market_id,
          offchain_status: 'paused',
          offchain_status_reason: 'matching_timeout',
          offchain_status_updated_at: 10.minutes.ago
        )

        expect(redis_mock).to receive(:lpush)
          .with("match_failed_queue:#{market_id}", anything)

        subject.perform
      end

      it 'skips when no paused orders found' do
        # No orders created - should skip
        expect(redis_mock).not_to receive(:lpush)
        subject.perform
      end

      it 'does not process recently paused orders' do
        recent_order = create(:trading_order,
          market_id: market_id,
          offchain_status: 'paused',
          offchain_status_reason: 'matching_timeout',
          offchain_status_updated_at: 1.minute.ago
        )

        expect(redis_mock).not_to receive(:lpush)
        subject.perform
      end

      it 'groups orders by market when enqueuing' do
        order1 = create(:trading_order,
          market_id: '2800',
          offchain_status: 'paused',
          offchain_status_reason: 'matching_timeout',
          offchain_status_updated_at: 10.minutes.ago
        )
        order2 = create(:trading_order,
          market_id: '2801',
          offchain_status: 'paused',
          offchain_status_reason: 'matching_timeout',
          offchain_status_updated_at: 10.minutes.ago
        )

        expect(redis_mock).to receive(:lpush).twice
        subject.perform
      end

      it 'only processes orders with matching_timeout reason' do
        order_with_reason = create(:trading_order,
          market_id: market_id,
          offchain_status: 'paused',
          offchain_status_reason: 'matching_timeout',
          offchain_status_updated_at: 10.minutes.ago
        )
        order_without_reason = create(:trading_order,
          market_id: market_id,
          offchain_status: 'paused',
          offchain_status_reason: 'other_reason',
          offchain_status_updated_at: 10.minutes.ago
        )

        expect(redis_mock).to receive(:lpush).once
        subject.perform
      end
    end

    context 'when not leader' do
      before do
        allow(Sidekiq::Election::Service).to receive(:leader?).and_return(false)
      end

      it 'skips execution' do
        create(:trading_order,
          market_id: market_id,
          offchain_status: 'paused',
          offchain_status_reason: 'matching_timeout',
          offchain_status_updated_at: 10.minutes.ago
        )

        expect(redis_mock).not_to receive(:lpush)
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

  describe 'constants' do
    it 'defines RESCAN_THRESHOLD as 5 minutes' do
      expect(described_class::RESCAN_THRESHOLD).to eq(5.minutes)
    end

    it 'defines BATCH_SIZE as 50' do
      expect(described_class::BATCH_SIZE).to eq(50)
    end
  end

  describe 'sidekiq configuration' do
    it 'uses the scheduler queue' do
      expect(described_class.sidekiq_options['queue'].to_s).to eq('scheduler')
    end

    it 'has retry set to 1' do
      expect(described_class.sidekiq_options['retry']).to eq(1)
    end
  end
end
