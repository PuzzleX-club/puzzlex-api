# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Orders::OrderHelper do
  include ServiceTestHelpers

  before do
    stub_redis
    stub_action_cable
    stub_sidekiq_workers
  end

  describe '.calculate_unfill_amount' do
    context 'when order not found' do
      it 'returns nil' do
        result = described_class.calculate_unfill_amount(99999)

        expect(result).to be_nil
      end
    end

    context 'with Offer order (buy order)' do
      let(:order) do
        create(:trading_order,
               order_direction: 'Offer',
               consideration_start_amount: 100,
               consideration_end_amount: 100,
               start_time: 1.hour.ago.to_i,
               end_time: 1.hour.from_now.to_i,
               total_filled: 0,
               total_size: 100)
      end

      it 'calculates unfilled amount based on consideration amounts' do
        result = described_class.calculate_unfill_amount(order.id)

        # consideration_start_amount == consideration_end_amount == 100
        # total_filled=0, total_size=100 => fill_progress=0.0
        # total_possible_amount = 100 + (100-100)*time_progress = 100
        # unfilled = 100 * (1 - 0.0) = 100
        expect(result).to eq(100)
      end
    end

    context 'with List order (sell order)' do
      let(:order) do
        create(:trading_order,
               order_direction: 'List',
               offer_start_amount: 50,
               offer_end_amount: 50,
               start_time: 1.hour.ago.to_i,
               end_time: 1.hour.from_now.to_i,
               total_filled: 25,
               total_size: 100)
      end

      it 'calculates unfilled amount based on offer amounts and fill progress' do
        result = described_class.calculate_unfill_amount(order.id)

        # offer_start_amount == offer_end_amount == 50
        # total_filled=25, total_size=100 => fill_progress=0.25
        # total_possible_amount = 50 + (50-50)*time_progress = 50
        # unfilled = 50 * (1 - 0.25) = 37.5 => 37 (to_i)
        expect(result).to eq(37)
      end
    end

    context 'with unknown order direction' do
      let(:order) do
        create(:trading_order,
               order_direction: 'Unknown',
               start_time: 1.hour.ago.to_i,
               end_time: 1.hour.from_now.to_i)
      end

      it 'returns nil' do
        result = described_class.calculate_unfill_amount(order.id)

        expect(result).to be_nil
      end
    end
  end

  describe '.calculate_total_amount' do
    let(:order) do
      create(:trading_order,
             offer_start_amount: 100,
             offer_end_amount: 200,
             start_time: 2.hours.ago.to_i,
             end_time: 2.hours.from_now.to_i,
             total_filled: 0,
             total_size: 100)
    end

    it 'returns nil when order not found' do
      result = described_class.calculate_total_amount(99999)

      expect(result).to be_nil
    end

    it 'calculates total possible amount based on time progress' do
      result = described_class.calculate_total_amount(order.id)

      # order has no explicit order_direction, factory default applies
      # offer_start_amount=100, offer_end_amount=200
      # start_time=2h ago, end_time=2h from now => time_progress ~0.5
      # total_possible_amount = 100 + (200-100)*0.5 = 150
      expect(result).to be_between(130, 170)
    end
  end

  describe '.calculate_price_in_progress' do
    let(:order) do
      create(:trading_order,
             start_price: '100',
             end_price: '200',
             start_time: 2.hours.ago.to_i,
             end_time: 2.hours.from_now.to_i)
    end

    it 'returns nil when order not found' do
      result = described_class.calculate_price_in_progress(99999)

      expect(result).to be_nil
    end

    it 'calculates interpolated price based on time progress' do
      result = described_class.calculate_price_in_progress(order.id)

      # At ~50% time progress: 100 + (200-100) * 0.5 = 150
      expect(result).to be_a(Float)
      expect(result).to be_between(100.0, 200.0)
    end
  end

  describe '.calculate_time_progress' do
    context 'with valid time range' do
      let(:order) do
        double('Order',
               start_time: 2.hours.ago.to_i,
               end_time: 2.hours.from_now.to_i)
      end

      it 'returns progress between 0 and 1' do
        result = described_class.calculate_time_progress(order)

        expect(result).to be_a(Float)
        expect(result).to be_between(0.0, 1.0)
      end

      it 'returns approximately 0.5 at midpoint' do
        result = described_class.calculate_time_progress(order)

        # Allow some tolerance for test execution time
        expect(result).to be_within(0.1).of(0.5)
      end
    end

    context 'with zero time range' do
      let(:order) do
        now = Time.now.to_i
        double('Order', start_time: now, end_time: now)
      end

      it 'returns 0.0' do
        result = described_class.calculate_time_progress(order)

        expect(result).to eq(0.0)
      end
    end

    context 'when order has not started' do
      let(:order) do
        double('Order',
               start_time: 1.hour.from_now.to_i,
               end_time: 2.hours.from_now.to_i)
      end

      it 'returns negative progress (before clamping)' do
        result = described_class.calculate_time_progress(order)

        # The current implementation doesn't clamp, so it can be negative
        expect(result).to be < 0
      end
    end

    context 'when order has ended' do
      let(:order) do
        double('Order',
               start_time: 3.hours.ago.to_i,
               end_time: 1.hour.ago.to_i)
      end

      it 'returns progress greater than 1 (before clamping)' do
        result = described_class.calculate_time_progress(order)

        # The current implementation doesn't clamp return value
        expect(result).to be > 1
      end
    end
  end

  describe '.calculate_fill_progress' do
    context 'with valid fill data' do
      let(:order) do
        double('Order',
               total_filled: 50,
               total_size: 100)
      end

      it 'returns progress as ratio of filled to total' do
        result = described_class.calculate_fill_progress(order)

        expect(result).to eq(0.5)
      end
    end

    context 'when fully filled' do
      let(:order) do
        double('Order',
               total_filled: 100,
               total_size: 100)
      end

      it 'returns 1.0' do
        result = described_class.calculate_fill_progress(order)

        expect(result).to eq(1.0)
      end
    end

    context 'when total_size is zero' do
      let(:order) do
        double('Order',
               total_filled: 0,
               total_size: 0)
      end

      it 'returns 0.0' do
        result = described_class.calculate_fill_progress(order)

        expect(result).to eq(0.0)
      end
    end

    context 'when overfilled (edge case)' do
      let(:order) do
        double('Order',
               total_filled: 150,
               total_size: 100)
      end

      it 'returns progress > 1 (clamp call exists but result not assigned)' do
        result = described_class.calculate_fill_progress(order)

        # Note: The implementation has a bug - clamp is called but result is not assigned
        # This test documents the actual behavior
        expect(result).to eq(1.5)
      end
    end
  end

  describe '.calculate_total_filled' do
    let(:order) { create(:trading_order) }
    let!(:event_record) { create(:trading_order_event, order_hash: order.order_hash) }
    let!(:order_item) { create(:trading_order_item, order: order) }

    context 'with no fills' do
      it 'returns 0' do
        result = described_class.calculate_total_filled(order.id)

        expect(result).to eq(0)
      end
    end

    context 'with fills' do
      before do
        create(:trading_order_fill, order: order, order_item: order_item, filled_amount: 10, event_id: event_record.id)
        create(:trading_order_fill, order: order, order_item: order_item, filled_amount: 20, event_id: event_record.id)
      end

      it 'returns sum of all filled amounts' do
        result = described_class.calculate_total_filled(order.id)

        expect(result).to eq(30)
      end
    end
  end

  describe '.calculate_filled_amt' do
    let(:order) { create(:trading_order) }
    let!(:event_record) { create(:trading_order_event, order_hash: order.order_hash) }
    let!(:order_item) { create(:trading_order_item, order: order) }

    context 'with no fills' do
      it 'returns 0.0' do
        result = described_class.calculate_filled_amt(order.id)

        expect(result).to eq(0.0)
      end
    end

    context 'with valid distribution (single element array)' do
      before do
        create(:trading_order_fill,
               order: order,
               order_item: order_item,
               filled_amount: 10,
               price_distribution: [{ 'total_amount' => '500' }],
               event_id: event_record.id)
        create(:trading_order_fill,
               order: order,
               order_item: order_item,
               filled_amount: 20,
               price_distribution: [{ 'total_amount' => '300' }],
               event_id: event_record.id)
      end

      it 'returns sum of total_amounts' do
        result = described_class.calculate_filled_amt(order.id)

        expect(result).to eq(800.0)
      end
    end

    context 'with invalid distribution (not single element array)' do
      before do
        create(:trading_order_fill,
               order: order,
               order_item: order_item,
               filled_amount: 10,
               price_distribution: [{ 'total_amount' => '500' }, { 'total_amount' => '100' }],
               event_id: event_record.id)
      end

      it 'returns -1' do
        result = described_class.calculate_filled_amt(order.id)

        expect(result).to eq(-1)
      end
    end
  end

  describe '.parse_onchain_status' do
    it 'returns 0 for pending' do
      order = double('Order', onchain_status: 'pending')

      expect(described_class.parse_onchain_status(order)).to eq(0)
    end

    it 'returns 1 for validated' do
      order = double('Order', onchain_status: 'validated')

      expect(described_class.parse_onchain_status(order)).to eq(1)
    end

    it 'returns 2 for partially_filled' do
      order = double('Order', onchain_status: 'partially_filled')

      expect(described_class.parse_onchain_status(order)).to eq(2)
    end

    it 'returns 3 for filled' do
      order = double('Order', onchain_status: 'filled')

      expect(described_class.parse_onchain_status(order)).to eq(3)
    end

    it 'returns 4 for cancelled' do
      order = double('Order', onchain_status: 'cancelled')

      expect(described_class.parse_onchain_status(order)).to eq(4)
    end

    it 'returns 9 for unknown status' do
      order = double('Order', onchain_status: 'weird_status')

      expect(described_class.parse_onchain_status(order)).to eq(9)
    end

    it 'handles numeric status 0' do
      order = double('Order', onchain_status: 0)

      expect(described_class.parse_onchain_status(order)).to eq(0)
    end

    it 'handles numeric status 1' do
      order = double('Order', onchain_status: 1)

      expect(described_class.parse_onchain_status(order)).to eq(1)
    end
  end
end
