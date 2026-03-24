# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Orders::OrderStatusManager, type: :service do
  include ActiveSupport::Testing::TimeHelpers

  before do
    allow(Redis).to receive(:current).and_return(double('Redis',
      keys: [],
      get: nil,
      set: true,
      setex: true
    ))
    allow(ActionCable.server).to receive(:broadcast)
    allow(Jobs::Matching::Worker).to receive(:perform_in)
  end

  let(:order) { create(:trading_order, offchain_status: 'active') }
  let(:manager) { described_class.new(order) }

  describe 'OFFCHAIN_TRANSITIONS' do
    it 'is frozen' do
      expect(described_class::OFFCHAIN_TRANSITIONS).to be_frozen
    end

    it 'defines terminal states with no transitions' do
      expect(described_class::OFFCHAIN_TRANSITIONS['expired']).to eq([])
      expect(described_class::OFFCHAIN_TRANSITIONS['closed']).to eq([])
      expect(described_class::OFFCHAIN_TRANSITIONS['match_failed']).to eq([])
    end
  end

  describe '#set_offchain_status! - legal transitions' do
    context 'from active' do
      let(:order) { create(:trading_order, offchain_status: 'active') }

      %w[matching over_matched expired paused validation_failed].each do |target|
        it "allows transition to #{target}" do
          expect { manager.set_offchain_status!(target, 'test') }.not_to raise_error
          expect(order.reload.offchain_status).to eq(target)
        end
      end
    end

    context 'from matching' do
      let(:order) { create(:trading_order, offchain_status: 'matching') }

      %w[active paused closed].each do |target|
        it "allows transition to #{target}" do
          expect { manager.set_offchain_status!(target, 'test') }.not_to raise_error
          expect(order.reload.offchain_status).to eq(target)
        end
      end
    end

    context 'from paused' do
      let(:order) { create(:trading_order, offchain_status: 'paused') }

      %w[active expired over_matched closed match_failed].each do |target|
        it "allows transition to #{target}" do
          expect { manager.set_offchain_status!(target, 'test') }.not_to raise_error
          expect(order.reload.offchain_status).to eq(target)
        end
      end
    end

    context 'from over_matched' do
      let(:order) { create(:trading_order, offchain_status: 'over_matched') }

      it 'allows transition to active' do
        expect { manager.set_offchain_status!('active', 'test') }.not_to raise_error
        expect(order.reload.offchain_status).to eq('active')
      end
    end

    context 'from validation_failed' do
      let(:order) { create(:trading_order, offchain_status: 'validation_failed') }

      it 'allows transition to active' do
        expect { manager.set_offchain_status!('active', 'recovered') }.not_to raise_error
        expect(order.reload.offchain_status).to eq('active')
      end
    end
  end

  describe '#set_offchain_status! - illegal transitions' do
    context 'from active' do
      let(:order) { create(:trading_order, offchain_status: 'active') }

      it 'rejects transition to closed' do
        expect { manager.set_offchain_status!('closed') }.to raise_error(ArgumentError, /非法链下状态转换/)
      end

      it 'rejects transition to match_failed' do
        expect { manager.set_offchain_status!('match_failed') }.to raise_error(ArgumentError, /非法链下状态转换/)
      end
    end

    context 'from terminal states' do
      it 'rejects any transition from expired' do
        order = create(:trading_order, offchain_status: 'expired')
        mgr = described_class.new(order)
        expect { mgr.set_offchain_status!('active') }.to raise_error(ArgumentError, /非法链下状态转换/)
      end

      it 'rejects any transition from closed' do
        order = create(:trading_order, offchain_status: 'closed')
        mgr = described_class.new(order)
        expect { mgr.set_offchain_status!('active') }.to raise_error(ArgumentError, /非法链下状态转换/)
      end

      it 'rejects any transition from match_failed' do
        order = create(:trading_order, offchain_status: 'match_failed')
        mgr = described_class.new(order)
        expect { mgr.set_offchain_status!('active') }.to raise_error(ArgumentError, /非法链下状态转换/)
      end
    end

    context 'from matching' do
      let(:order) { create(:trading_order, offchain_status: 'matching') }

      it 'rejects transition to over_matched' do
        expect { manager.set_offchain_status!('over_matched') }.to raise_error(ArgumentError, /非法链下状态转换/)
      end

      it 'rejects transition to expired' do
        expect { manager.set_offchain_status!('expired') }.to raise_error(ArgumentError, /非法链下状态转换/)
      end
    end
  end

  describe '#set_offchain_status! - same status (no-op)' do
    it 'does not raise when transitioning to same status' do
      expect { manager.set_offchain_status!('active') }.not_to raise_error
    end
  end

  describe '#set_offchain_status! - unknown status' do
    it 'rejects unknown status values' do
      expect { manager.set_offchain_status!('nonexistent') }.to raise_error(ArgumentError, /未知链下状态/)
    end
  end

  describe '#set_offchain_status! - metadata tracking' do
    it 'records reason' do
      manager.set_offchain_status!('matching', 'order_match_worker triggered')
      expect(order.reload.offchain_status_reason).to eq('order_match_worker triggered')
    end

    it 'updates offchain_status_updated_at' do
      original_time = order.offchain_status_updated_at
      travel 1.hour do
        manager.set_offchain_status!('matching')
        expect(order.reload.offchain_status_updated_at).not_to eq(original_time)
      end
    end

    it 'creates status log entry' do
      expect {
        manager.set_offchain_status!('matching', 'test')
      }.to change(Trading::OrderStatusLog, :count).by(1)
    end
  end

  describe '#update_onchain_status!' do
    let(:order) { create(:trading_order, onchain_status: 'pending', is_validated: false, total_filled: 0, total_size: 100) }

    context 'when order becomes validated' do
      it 'sets onchain_status to validated' do
        manager.update_onchain_status!(
          is_validated: true,
          is_cancelled: false,
          total_filled: 0,
          total_size: 100
        )
        expect(order.reload.onchain_status).to eq('validated')
      end
    end

    context 'when order becomes partially filled' do
      let(:order) { create(:trading_order, onchain_status: 'validated', is_validated: true, total_filled: 0, total_size: 100) }

      it 'sets onchain_status to partially_filled' do
        manager.update_onchain_status!(
          is_validated: true,
          is_cancelled: false,
          total_filled: 50,
          total_size: 100
        )
        expect(order.reload.onchain_status).to eq('partially_filled')
      end
    end

    context 'when order becomes fully filled' do
      let(:order) { create(:trading_order, onchain_status: 'validated', is_validated: true, total_filled: 0, total_size: 100) }

      it 'sets onchain_status to filled and syncs offchain to closed' do
        manager.update_onchain_status!(
          is_validated: true,
          is_cancelled: false,
          total_filled: 100,
          total_size: 100
        )
        expect(order.reload.onchain_status).to eq('filled')
        expect(order.offchain_status).to eq('closed')
      end
    end

    context 'when order is cancelled' do
      let(:order) { create(:trading_order, onchain_status: 'validated', is_validated: true, total_filled: 0, total_size: 100) }

      it 'sets onchain_status to cancelled and syncs offchain to closed' do
        manager.update_onchain_status!(
          is_validated: true,
          is_cancelled: true,
          total_filled: 0,
          total_size: 100
        )
        expect(order.reload.onchain_status).to eq('cancelled')
        expect(order.offchain_status).to eq('closed')
      end
    end

    context 'when order is partially filled then fully filled (remainder scenario)' do
      let(:order) { create(:trading_order, onchain_status: 'validated', is_validated: true, total_filled: 0, total_size: 100) }

      it 'progresses through partially_filled to filled' do
        # Round 1: partial fill
        manager.update_onchain_status!(
          is_validated: true,
          is_cancelled: false,
          total_filled: 60,
          total_size: 100
        )
        expect(order.reload.onchain_status).to eq('partially_filled')

        # Round 2: complete fill
        manager.update_onchain_status!(
          is_validated: true,
          is_cancelled: false,
          total_filled: 100,
          total_size: 100
        )
        expect(order.reload.onchain_status).to eq('filled')
        expect(order.offchain_status).to eq('closed')
      end
    end
  end
end
