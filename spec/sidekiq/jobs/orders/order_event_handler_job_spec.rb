# frozen_string_literal: true

require "rails_helper"

RSpec.describe Jobs::Orders::OrderEventHandlerJob, type: :job do
  subject(:perform_job) { described_class.new.perform(event.id) }

  before do
    allow(Infrastructure::EventBus).to receive(:publish)
    allow(Orders::SpreadAllocationRecorder).to receive(:record_for_match_event!)
    allow_any_instance_of(Trading::OrderFill).to receive(:enqueue_trade_broadcast)
    allow_any_instance_of(Trading::OrderFill).to receive(:mark_market_changed)
  end

  def create_fill_for(order:, transaction_hash:, log_index: nil)
    @fill_log_index ||= 0
    log_index ||= @fill_log_index
    @fill_log_index += 1

    order_item = create(:trading_order_item, order: order)
    create(
      :trading_order_fill,
      order: order,
      order_item: order_item,
      transaction_hash: transaction_hash,
      log_index: log_index,
      matched_event_id: nil,
      buyer_address: nil,
      seller_address: nil
    )
  end

  describe "OrdersMatched event handling" do
    let(:transaction_hash) { "0x#{SecureRandom.hex(32)}" }

    context "with 1v1 matched_orders" do
      let!(:sell_order) { create(:trading_order, :list, offerer: "0x1111111111111111111111111111111111111111") }
      let!(:buy_order) { create(:trading_order, :offer, offerer: "0x2222222222222222222222222222222222222222") }
      let!(:sell_fill) { create_fill_for(order: sell_order, transaction_hash: transaction_hash) }
      let!(:buy_fill) { create_fill_for(order: buy_order, transaction_hash: transaction_hash) }

      let(:event) do
        create(
          :trading_order_event,
          event_name: "OrdersMatched",
          order_hash: nil,
          transaction_hash: transaction_hash,
          matched_orders: [sell_order.order_hash, buy_order.order_hash].to_json
        )
      end

      it "updates matched_event_id and counterparty address for fills" do
        perform_job

        expect(sell_fill.reload.matched_event_id).to eq(event.id)
        expect(buy_fill.reload.matched_event_id).to eq(event.id)
        expect(sell_fill.reload.buyer_address).to eq(buy_order.offerer)
        expect(buy_fill.reload.seller_address).to eq(sell_order.offerer)
      end

      it "records spread allocation in 1v1 flow" do
        perform_job

        expect(Orders::SpreadAllocationRecorder).to have_received(:record_for_match_event!).once
      end
    end

    context "with 1vN matched_orders" do
      let!(:sell_orders) do
        [
          create(:trading_order, :list, offerer: "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"),
          create(:trading_order, :list, offerer: "0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"),
          create(:trading_order, :list, offerer: "0xcccccccccccccccccccccccccccccccccccccccc")
        ]
      end
      let!(:buy_order) { create(:trading_order, :offer, offerer: "0xdddddddddddddddddddddddddddddddddddddddd") }
      let!(:sell_fills) { sell_orders.map { |order| create_fill_for(order: order, transaction_hash: transaction_hash) } }
      let!(:buy_fill) { create_fill_for(order: buy_order, transaction_hash: transaction_hash) }

      let(:event) do
        create(
          :trading_order_event,
          event_name: "OrdersMatched",
          order_hash: nil,
          transaction_hash: transaction_hash,
          matched_orders: (sell_orders.map(&:order_hash) + [buy_order.order_hash]).to_json
        )
      end

      it "updates matched_event_id for all related fills and sets buyer_address for sell fills" do
        perform_job

        sell_fills.each do |fill|
          fill.reload
          expect(fill.matched_event_id).to eq(event.id)
          expect(fill.buyer_address).to eq(buy_order.offerer)
        end

        expect(buy_fill.reload.matched_event_id).to eq(event.id)
        expect(buy_fill.reload.seller_address).to be_nil
      end

      it "skips spread allocation for multi-order match" do
        perform_job

        expect(Orders::SpreadAllocationRecorder).not_to have_received(:record_for_match_event!)
      end
    end
  end
end
