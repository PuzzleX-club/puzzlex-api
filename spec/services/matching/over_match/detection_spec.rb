require 'rails_helper'

RSpec.describe Matching::OverMatch::Detection do
  let(:player_address) { '0x' + 'a' * 40 }
  let(:token_id) { '1048833' }  # 结构化tokenId
  let(:currency_address) { '0x' + 'b' * 40 }

  before do
    # Clean up any existing test data
    Trading::Order.delete_all
  end

  describe '.check_player_orders' do
    context 'when player has no orders' do
      before do
        allow(described_class).to receive(:get_active_sell_orders).and_return([])
        allow(described_class).to receive(:get_active_buy_orders).and_return([])
      end

      it 'returns empty results' do
        result = described_class.check_player_orders(player_address)

        expect(result[:player_address]).to eq(player_address)
        expect(result[:checked_at]).to be_present
        expect(result[:token_checks]).to be_empty
        expect(result[:currency_checks]).to be_empty
        expect(result[:total_over_matched]).to eq(0)
        expect(result[:total_restored]).to eq(0)
      end

      it 'logs the check process' do
        expect(Rails.logger).to receive(:info).with(/开始检测玩家/)
        expect(Rails.logger).to receive(:info).with(/检测完成/)

        described_class.check_player_orders(player_address)
      end
    end

    context 'when player has orders' do
      let(:sell_order) { create(:trading_order, order_direction: 'List', offerer: player_address) }
      let(:buy_order) { create(:trading_order, order_direction: 'Offer', offerer: player_address) }

      before do
        allow(described_class).to receive(:get_active_sell_orders).and_return([sell_order])
        allow(described_class).to receive(:get_active_buy_orders).and_return([buy_order])
        allow(described_class).to receive(:check_token_id_balance).and_return({
          token_id: token_id,
          over_matched_count: 1,
          restored_count: 0
        })
        allow(described_class).to receive(:check_currency_balance).and_return({
          currency_address: currency_address,
          over_matched_count: 0,
          restored_count: 1
        })
      end

      it 'checks both token and currency balances' do
        result = described_class.check_player_orders(player_address)

        expect(result[:token_checks].length).to eq(1)
        expect(result[:currency_checks].length).to eq(1)
        expect(result[:total_over_matched]).to eq(1)
        expect(result[:total_restored]).to eq(1)
      end
    end
  end

  describe '.check_token_balances' do
    context 'with multiple orders for same token' do
      let(:order1) { create(:trading_order, order_direction: 'List', offerer: player_address) }
      let(:order2) { create(:trading_order, order_direction: 'List', offerer: player_address) }

      before do
        allow(described_class).to receive(:get_active_sell_orders).and_return([order1, order2])
        allow(described_class).to receive(:get_order_token_id).and_return(token_id)
        allow(described_class).to receive(:check_token_id_balance).and_return({
          token_id: token_id,
          over_matched_count: 0,
          restored_count: 0
        })
      end

      it 'groups orders by token_id and checks balance' do
        expect(described_class).to receive(:check_token_id_balance).once

        results = described_class.check_token_balances(player_address)
        expect(results.length).to eq(1)
      end
    end

    context 'with orders for different tokens' do
      let(:token_id_2) { '1048834' }
      let(:order1) { create(:trading_order, order_direction: 'List', offerer: player_address) }
      let(:order2) { create(:trading_order, order_direction: 'List', offerer: player_address) }

      before do
        allow(described_class).to receive(:get_active_sell_orders).and_return([order1, order2])
        allow(described_class).to receive(:get_order_token_id).and_return(token_id, token_id_2)
        allow(described_class).to receive(:check_token_id_balance).and_return({
          over_matched_count: 0,
          restored_count: 0
        })
      end

      it 'checks each token separately' do
        expect(described_class).to receive(:check_token_id_balance).twice

        results = described_class.check_token_balances(player_address)
        expect(results.length).to eq(2)
      end
    end

    context 'with blank token_id' do
      let(:order) { create(:trading_order, order_direction: 'List', offerer: player_address) }

      before do
        allow(described_class).to receive(:get_active_sell_orders).and_return([order])
        allow(described_class).to receive(:get_order_token_id).and_return(nil)
      end

      it 'skips orders with blank token_id' do
        expect(described_class).not_to receive(:check_token_id_balance)

        results = described_class.check_token_balances(player_address)
        expect(results).to be_empty
      end
    end
  end

  describe '.check_currency_balances' do
    context 'with multiple orders for same currency' do
      let(:order1) { create(:trading_order, order_direction: 'Offer', offerer: player_address) }
      let(:order2) { create(:trading_order, order_direction: 'Offer', offerer: player_address) }

      before do
        allow(described_class).to receive(:get_active_buy_orders).and_return([order1, order2])
        allow(described_class).to receive(:get_order_currency_address).and_return(currency_address)
        allow(described_class).to receive(:check_currency_balance).and_return({
          currency_address: currency_address,
          over_matched_count: 0,
          restored_count: 0
        })
      end

      it 'groups orders by currency and checks balance' do
        expect(described_class).to receive(:check_currency_balance).once

        results = described_class.check_currency_balances(player_address)
        expect(results.length).to eq(1)
      end
    end

    context 'with blank currency_address' do
      let(:order) { create(:trading_order, order_direction: 'Offer', offerer: player_address) }

      before do
        allow(described_class).to receive(:get_active_buy_orders).and_return([order])
        allow(described_class).to receive(:get_order_currency_address).and_return(nil)
      end

      it 'skips orders with blank currency_address' do
        expect(described_class).not_to receive(:check_currency_balance)

        results = described_class.check_currency_balances(player_address)
        expect(results).to be_empty
      end
    end
  end

  describe '.get_active_sell_orders' do
    let!(:active_sell) { create(:trading_order, order_direction: 'List', offerer: player_address, onchain_status: 'validated') }
    let!(:inactive_sell) { create(:trading_order, order_direction: 'List', offerer: player_address, onchain_status: 'filled') }
    let!(:other_player_sell) { create(:trading_order, order_direction: 'List', offerer: '0x' + 'c' * 40, onchain_status: 'validated') }

    it 'returns only active sell orders for the player' do
      orders = described_class.get_active_sell_orders(player_address)

      expect(orders).to include(active_sell)
      expect(orders).not_to include(inactive_sell)
      expect(orders).not_to include(other_player_sell)
    end
  end

  describe '.get_active_buy_orders' do
    let!(:active_buy) { create(:trading_order, order_direction: 'Offer', offerer: player_address, onchain_status: 'validated') }
    let!(:inactive_buy) { create(:trading_order, order_direction: 'Offer', offerer: player_address, onchain_status: 'filled') }
    let!(:other_player_buy) { create(:trading_order, order_direction: 'Offer', offerer: '0x' + 'c' * 40, onchain_status: 'validated') }

    it 'returns only active buy orders for the player' do
      orders = described_class.get_active_buy_orders(player_address)

      expect(orders).to include(active_buy)
      expect(orders).not_to include(inactive_buy)
      expect(orders).not_to include(other_player_buy)
    end
  end

  describe '.get_order_token_id' do
    context 'with offer containing identifier' do
      let(:order) { create(:trading_order, order_direction: 'List', offer_identifier: token_id) }

      it 'extracts token_id from order' do
        result = described_class.get_order_token_id(order)
        expect(result).to eq(token_id)
      end
    end

    context 'with invalid order direction' do
      let(:order) { create(:trading_order, order_direction: 'Invalid') }

      it 'returns nil gracefully' do
        result = described_class.get_order_token_id(order)
        expect(result).to be_nil
      end
    end
  end

  describe '.get_order_currency_address' do
    context 'with List order containing consideration token' do
      let(:order) { create(:trading_order, order_direction: 'List', consideration_token: currency_address) }

      it 'extracts currency address from order' do
        result = described_class.get_order_currency_address(order)
        expect(result).to eq(currency_address)
      end
    end

    context 'with invalid order direction' do
      let(:order) { create(:trading_order, order_direction: 'Invalid') }

      it 'returns nil gracefully' do
        result = described_class.get_order_currency_address(order)
        expect(result).to be_nil
      end
    end
  end

  describe '.calculate_order_token_amount' do
    let(:order) { create(:trading_order) }

    context 'with List order and valid offer amount' do
      let(:order) { create(:trading_order, order_direction: 'List', offer_start_amount: 100) }

      it 'returns token amount as integer' do
        result = described_class.calculate_order_token_amount(order)
        expect(result).to eq(100)
      end
    end

    context 'with missing amount' do
      let(:order) { create(:trading_order, order_direction: 'List', offer_start_amount: nil) }

      it 'returns 0' do
        result = described_class.calculate_order_token_amount(order)
        expect(result).to eq(0)
      end
    end
  end

  describe '.calculate_order_currency_amount' do
    let(:order) { create(:trading_order) }

    context 'with List order and valid consideration amount' do
      let(:order) { create(:trading_order, order_direction: 'List', consideration_start_amount: 1000) }

      it 'returns currency amount as integer' do
        result = described_class.calculate_order_currency_amount(order)
        expect(result).to eq(1000)
      end
    end

    context 'with missing amount' do
      let(:order) { create(:trading_order, order_direction: 'List', consideration_start_amount: nil) }

      it 'returns 0' do
        result = described_class.calculate_order_currency_amount(order)
        expect(result).to eq(0)
      end
    end
  end

  describe 'integration scenario' do
    let(:order1) { create(:trading_order, order_direction: 'List', offerer: player_address, onchain_status: 'validated') }
    let(:order2) { create(:trading_order, order_direction: 'List', offerer: player_address, onchain_status: 'validated') }

    before do
      # Mock the order queries to return our test orders
      allow(described_class).to receive(:get_active_sell_orders).and_return([order1, order2])
      allow(described_class).to receive(:get_active_buy_orders).and_return([])

      # Mock token_id extraction
      allow(described_class).to receive(:get_order_token_id).and_return(token_id)

      # Mock balance and amount calculations
      allow(described_class).to receive(:get_player_token_balance).and_return(50)
      allow(described_class).to receive(:calculate_order_token_amount).and_return(30, 30)

      # Mock backup/restore operations
      allow(described_class).to receive(:backup_and_set_over_matched).and_return(true)
    end

    it 'detects over-matched orders when total exceeds balance' do
      # Total orders: 60 (30+30), Balance: 50 -> Over-matched!
      result = described_class.check_player_orders(player_address)

      expect(result[:token_checks]).not_to be_empty
      # Over-match detection should trigger
    end
  end
end
