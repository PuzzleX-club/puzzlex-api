# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Orders::EventApplier do
  include ServiceTestHelpers

  before do
    stub_redis
    stub_action_cable
    stub_sidekiq_workers
  end

  describe '.apply_event' do
    let(:order) { create(:trading_order, order_hash: '0xorderhash123', onchain_status: 'pending') }
    let(:event_record) do
      double('EventRecord',
             id: 1,
             synced: false,
             event_name: event_name,
             order_hash: '0xorderhash123',
             transaction_hash: '0xtxhash',
             log_index: 1,
             block_number: 12345,
             block_timestamp: Time.current.to_i,
             matched_orders: nil,
             attributes: {})
    end

    before do
      allow(event_record).to receive(:update!).and_return(true)
    end

    context 'when event is already synced' do
      let(:event_name) { 'OrderValidated' }
      let(:synced_event) do
        double('EventRecord', synced: true)
      end

      it 'returns early without processing' do
        expect(Orders::OrderStatusUpdater).not_to receive(:update_order_status)

        described_class.apply_event(synced_event)
      end
    end

    context 'when event_name is OrderValidated' do
      let(:event_name) { 'OrderValidated' }
      let(:manager) { instance_double(Orders::OrderStatusManager) }

      before do
        allow(Trading::Order).to receive(:find_by).with(order_hash: '0xorderhash123').and_return(order)
        allow(Orders::OrderStatusUpdater).to receive(:update_order_status).and_return({ status: 'validated' })
        allow(Orders::OrderStatusManager).to receive(:new).with(order).and_return(manager)
        allow(manager).to receive(:set_offchain_status!).and_return(true)
        allow(order).to receive(:update!).and_return(true)
      end

      it 'sets offchain status to active' do
        expect(manager).to receive(:set_offchain_status!).with(
          'active',
          'chain_validated',
          hash_including(event: 'OrderValidated')
        )

        described_class.apply_event(event_record)
      end

      it 'calls OrderStatusUpdater to sync from chain' do
        expect(Orders::OrderStatusUpdater).to receive(:update_order_status).with('0xorderhash123')

        described_class.apply_event(event_record)
      end

      it 'marks event as synced' do
        expect(event_record).to receive(:update!).with(synced: true)

        described_class.apply_event(event_record)
      end
    end

    context 'when event_name is OrderFulfilled' do
      let(:event_name) { 'OrderFulfilled' }

      before do
        allow(Trading::Order).to receive(:find_by).with(order_hash: '0xorderhash123').and_return(order)
        allow(Orders::OrderStatusUpdater).to receive(:update_order_status).and_return({ status: 'filled' })
        allow(order).to receive(:update!).and_return(true)
      end

      it 'does not set initial status directly' do
        expect(order).not_to receive(:update!).with(onchain_status: anything)

        described_class.apply_event(event_record)
      end

      it 'calls OrderStatusUpdater to sync from chain' do
        expect(Orders::OrderStatusUpdater).to receive(:update_order_status).with('0xorderhash123')

        described_class.apply_event(event_record)
      end
    end

    context 'when event_name is OrderCancelled' do
      let(:event_name) { 'OrderCancelled' }

      before do
        allow(Trading::Order).to receive(:find_by).with(order_hash: '0xorderhash123').and_return(order)
        allow(Orders::OrderStatusUpdater).to receive(:update_order_status).and_return({ status: 'cancelled' })
        allow(order).to receive(:update!).and_return(true)
      end

      it 'calls OrderStatusUpdater' do
        expect(Orders::OrderStatusUpdater).to receive(:update_order_status).with('0xorderhash123')

        described_class.apply_event(event_record)
      end
    end

    context 'when event_name is OrdersMatched' do
      let(:event_name) { 'OrdersMatched' }
      let(:matched_order1) { create(:trading_order, order_hash: '0xmatch1', onchain_status: 'validated') }
      let(:matched_order2) { create(:trading_order, order_hash: '0xmatch2', onchain_status: 'validated') }
      let(:manager1) { instance_double(Orders::OrderStatusManager) }
      let(:manager2) { instance_double(Orders::OrderStatusManager) }

      let(:event_record) do
        double('EventRecord',
               id: 2,
               synced: false,
               event_name: 'OrdersMatched',
               order_hash: nil,
               transaction_hash: '0xtxhash_matched',
               log_index: 5,
               block_number: 12346,
               block_timestamp: Time.current.to_i,
               matched_orders: ['0xmatch1', '0xmatch2'].to_json,
               attributes: {})
      end

      before do
        allow(event_record).to receive(:update!).and_return(true)
        allow(Trading::Order).to receive(:find_by).with(order_hash: '0xmatch1').and_return(matched_order1)
        allow(Trading::Order).to receive(:find_by).with(order_hash: '0xmatch2').and_return(matched_order2)
        allow(Orders::OrderStatusUpdater).to receive(:update_order_status).and_return({ status: 'filled' })
        allow(Orders::OrderStatusManager).to receive(:new).with(matched_order1).and_return(manager1)
        allow(Orders::OrderStatusManager).to receive(:new).with(matched_order2).and_return(manager2)
        allow(manager1).to receive(:set_offchain_status!).and_return(true)
        allow(manager2).to receive(:set_offchain_status!).and_return(true)
        allow(matched_order1).to receive(:update!).and_return(true)
        allow(matched_order2).to receive(:update!).and_return(true)
      end

      it 'processes each matched order' do
        expect(Orders::OrderStatusUpdater).to receive(:update_order_status).with('0xmatch1')
        expect(Orders::OrderStatusUpdater).to receive(:update_order_status).with('0xmatch2')
        expect(manager1).to receive(:set_offchain_status!).with(
          'matching',
          'chain_matched',
          hash_including(event: 'OrdersMatched')
        )
        expect(manager2).to receive(:set_offchain_status!).with(
          'matching',
          'chain_matched',
          hash_including(event: 'OrdersMatched')
        )

        described_class.apply_event(event_record)
      end

      it 'marks event as synced after processing all orders' do
        expect(event_record).to receive(:update!).with(synced: true)

        described_class.apply_event(event_record)
      end
    end

    context 'when matched_orders is empty' do
      let(:event_name) { 'OrdersMatched' }
      let(:event_record) do
        double('EventRecord',
               id: 3,
               synced: false,
               event_name: 'OrdersMatched',
               order_hash: nil,
               matched_orders: [].to_json,
               attributes: {})
      end

      before do
        allow(event_record).to receive(:update!).and_return(true)
      end

      it 'marks event as synced without processing' do
        expect(Orders::OrderStatusUpdater).not_to receive(:update_order_status)
        expect(event_record).to receive(:update!).with(synced: true)

        described_class.apply_event(event_record)
      end
    end

    context 'when event_name is unhandled' do
      let(:event_name) { 'UnknownEvent' }
      let(:event_record) do
        double('EventRecord',
               synced: false,
               event_name: 'UnknownEvent')
      end

      before do
        allow(event_record).to receive(:update!).and_return(true)
      end

      it 'marks event as synced' do
        expect(event_record).to receive(:update!).with(synced: true)

        described_class.apply_event(event_record)
      end
    end
  end

  describe '.apply_single_order_event' do
    let(:order) { create(:trading_order, order_hash: '0xorderhash', synced_at: nil) }
    let(:event_record) do
      double('EventRecord',
             id: 1,
             event_name: 'OrderValidated',
             order_hash: '0xorderhash',
             transaction_hash: '0xtx',
             log_index: 1,
             block_number: 100,
             block_timestamp: Time.current.to_i,
             attributes: {})
    end

    before do
      allow(event_record).to receive(:update!).and_return(true)
    end

    context 'when order_hash is nil' do
      let(:event_record) do
        double('EventRecord',
               id: 1,
               event_name: 'OrderValidated',
               order_hash: nil)
      end

      before do
        allow(event_record).to receive(:update!).and_return(true)
      end

      it 'marks event as synced and returns early' do
        expect(event_record).to receive(:update!).with(synced: true)

        described_class.apply_single_order_event(event_record)
      end
    end

    context 'when order not found' do
      before do
        allow(Trading::Order).to receive(:find_by).with(order_hash: '0xorderhash').and_return(nil)
        allow(Trading::UnmatchedOrderEvent).to receive(:create!).and_return(true)
      end

      it 'records unmatched order event' do
        expect(Trading::UnmatchedOrderEvent).to receive(:create!).with(hash_including(order_hash: '0xorderhash'))

        described_class.apply_single_order_event(event_record)
      end

      it 'marks event as synced' do
        expect(event_record).to receive(:update!).with(synced: true)

        described_class.apply_single_order_event(event_record)
      end
    end

    context 'when order found and set_offchain_active is true' do
      let(:manager) { instance_double(Orders::OrderStatusManager) }

      before do
        allow(Trading::Order).to receive(:find_by).with(order_hash: '0xorderhash').and_return(order)
        allow(Orders::OrderStatusUpdater).to receive(:update_order_status).and_return({ status: 'validated' })
        allow(Orders::OrderStatusManager).to receive(:new).with(order).and_return(manager)
        allow(manager).to receive(:set_offchain_status!).and_return(true)
        allow(order).to receive(:update!).and_return(true)
      end

      it 'sets offchain status to active via OrderStatusManager' do
        expect(manager).to receive(:set_offchain_status!).with(
          'active',
          'chain_validated',
          hash_including(event: 'OrderValidated')
        )

        described_class.apply_single_order_event(event_record, set_offchain_active: true)
      end
    end

    context 'when OrderStatusUpdater returns error' do
      before do
        allow(Trading::Order).to receive(:find_by).with(order_hash: '0xorderhash').and_return(order)
        allow(Orders::OrderStatusUpdater).to receive(:update_order_status).and_return({ error: 'Network error' })
        allow(order).to receive(:update!).and_return(true)
      end

      it 'logs error but still marks event as synced' do
        expect(Rails.logger).to receive(:error).with(/Failed to update order status/)
        expect(event_record).to receive(:update!).with(synced: true)

        described_class.apply_single_order_event(event_record)
      end
    end
  end

  describe '.append_sync_record' do
    let(:order) { create(:trading_order, synced_at: nil) }
    let(:event_record) do
      double('EventRecord',
             id: 1,
             transaction_hash: '0xtxhash',
             log_index: 5)
    end

    it 'creates sync record with timestamp, hash, and log_index' do
      described_class.append_sync_record(order, event_record)

      order.reload
      sync_history = order.synced_at['synced_history']
      expect(sync_history).to be_present
      expect(sync_history.last['hash']).to eq('0xtxhash')
      expect(sync_history.last['logindex']).to eq(5)
      expect(sync_history.last['event_id']).to eq(1)
    end

    it 'appends to existing sync history' do
      order.update!(synced_at: { 'synced_history' => [{ 'hash' => '0xprevious' }] })

      described_class.append_sync_record(order, event_record)

      order.reload
      sync_history = order.synced_at['synced_history']
      expect(sync_history.length).to eq(2)
      expect(sync_history.first['hash']).to eq('0xprevious')
      expect(sync_history.last['hash']).to eq('0xtxhash')
    end
  end

  describe '.record_unmatched_order_event' do
    let(:event_record) do
      double('EventRecord',
             event_name: 'OrderValidated',
             transaction_hash: '0xtxhash',
             log_index: 3,
             block_number: 12345,
             block_timestamp: Time.current.to_i,
             attributes: { 'extra_data' => 'value' })
    end

    it 'creates UnmatchedOrderEvent record' do
      expect(Trading::UnmatchedOrderEvent).to receive(:create!).with(
        order_hash: '0xunknown',
        event_name: 'OrderValidated',
        transaction_hash: '0xtxhash',
        log_index: 3,
        block_number: 12345,
        block_timestamp: event_record.block_timestamp,
        event_data: event_record.attributes
      )

      described_class.record_unmatched_order_event(event_record, '0xunknown')
    end
  end

  describe '.create_items_and_fills' do
    let(:order) { create(:trading_order, market_id: 101) }
    let!(:event_record) { create(:trading_order_event, order_hash: order.order_hash) }
    let(:items_data) do
      [
        {
          'token_id' => '1001',
          'token_address' => '0xtoken',
          'role' => 'offer',
          'start_amount' => '10',
          'end_amount' => '10',
          'start_price_distribution' => [],
          'end_price_distribution' => []
        }
      ]
    end
    let(:fills_data) do
      [
        {
          'token_id' => '1001',
          'token_address' => '0xtoken',
          'filled_amount' => '5',
          'distribution' => [{ 'token_address' => '0xprice', 'total_amount' => '500', 'recipients' => [] }],
          'transaction_hash' => '0xtx',
          'log_index' => 1,
          'block_timestamp' => Time.current.to_i,
          'buyer_address' => '0xbuyer',
          'seller_address' => '0xseller',
          'event_id' => event_record.id
        }
      ]
    end

    it 'creates order items' do
      expect {
        described_class.create_items_and_fills(order, items_data, [])
      }.to change(Trading::OrderItem, :count).by(1)
    end

    it 'creates order fills linked to items' do
      expect {
        described_class.create_items_and_fills(order, items_data, fills_data)
      }.to change(Trading::OrderFill, :count).by(1)
    end

    it 'sets market_id from order' do
      described_class.create_items_and_fills(order, items_data, fills_data)

      fill = Trading::OrderFill.last
      expect(fill.market_id).to eq(101)
    end

    it 'skips duplicate items with same token_id' do
      # Create existing item
      Trading::OrderItem.create!(order: order, token_id: '1001', token_address: '0xtoken', role: 'offer')

      expect {
        described_class.create_items_and_fills(order, items_data, [])
      }.not_to change(Trading::OrderItem, :count)
    end

    it 'skips fills without matching item' do
      fills_with_unknown_token = [
        {
          'token_id' => '9999',
          'filled_amount' => '5',
          'distribution' => [],
          'transaction_hash' => '0xtx',
          'log_index' => 1,
          'block_timestamp' => Time.current.to_i,
          'event_id' => event_record.id
        }
      ]

      expect {
        described_class.create_items_and_fills(order, items_data, fills_with_unknown_token)
      }.not_to change(Trading::OrderFill, :count)
    end
  end
end
