# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Trading::Order, type: :model do
  subject { build(:trading_order) }

  before do
    # Global stubs in spec/support/global_external_stubs.rb handle Redis/ActionCable/Sidekiq
  end

  # ============================================
  # Factory Tests
  # ============================================
  describe 'factory' do
    it 'has a valid factory' do
      expect(build(:trading_order)).to be_valid
    end

    it 'can be persisted' do
      order = create(:trading_order)
      expect(order).to be_persisted
      expect(order.order_hash).to be_present
    end

    it 'creates list order with :list trait' do
      order = build(:trading_order, :list)
      expect(order.order_direction).to eq('List')
    end

    it 'creates offer order with :offer trait' do
      order = build(:trading_order, :offer)
      expect(order.order_direction).to eq('Offer')
    end
  end

  # ============================================
  # Validations
  # ============================================
  describe 'validations' do
    it { is_expected.to validate_presence_of(:offerer) }

    describe 'order_type validation' do
      it 'is valid with FULL_RESTRICTED type' do
        order = build(:trading_order, order_type: Trading::Order::OrderType::FULL_RESTRICTED)
        expect(order).to be_valid
      end

      it 'is valid with PARTIAL_RESTRICTED type' do
        order = build(:trading_order, order_type: Trading::Order::OrderType::PARTIAL_RESTRICTED)
        expect(order).to be_valid
      end

      it 'is invalid with FULL_OPEN type' do
        order = build(:trading_order, order_type: Trading::Order::OrderType::FULL_OPEN)
        expect(order).not_to be_valid
        expect(order.errors[:order_type]).to include(/只允许 FULL_RESTRICTED/)
      end

      it 'is invalid with PARTIAL_OPEN type' do
        order = build(:trading_order, order_type: Trading::Order::OrderType::PARTIAL_OPEN)
        expect(order).not_to be_valid
      end
    end
  end

  # ============================================
  # OrderType Module Constants
  # ============================================
  describe 'OrderType constants' do
    it 'defines FULL_OPEN as 0' do
      expect(Trading::Order::OrderType::FULL_OPEN).to eq(0)
    end

    it 'defines PARTIAL_OPEN as 1' do
      expect(Trading::Order::OrderType::PARTIAL_OPEN).to eq(1)
    end

    it 'defines FULL_RESTRICTED as 2' do
      expect(Trading::Order::OrderType::FULL_RESTRICTED).to eq(2)
    end

    it 'defines PARTIAL_RESTRICTED as 3' do
      expect(Trading::Order::OrderType::PARTIAL_RESTRICTED).to eq(3)
    end

    it 'defines CONTRACT as 4' do
      expect(Trading::Order::OrderType::CONTRACT).to eq(4)
    end
  end

  # ============================================
  # ItemType Module Constants
  # ============================================
  describe 'ItemType constants' do
    it 'defines NATIVE as 0' do
      expect(Trading::Order::ItemType::NATIVE).to eq(0)
    end

    it 'defines ERC20 as 1' do
      expect(Trading::Order::ItemType::ERC20).to eq(1)
    end

    it 'defines ERC721 as 2' do
      expect(Trading::Order::ItemType::ERC721).to eq(2)
    end

    it 'defines ERC1155 as 3' do
      expect(Trading::Order::ItemType::ERC1155).to eq(3)
    end

    it 'defines ERC721_WITH_CRITERIA as 4' do
      expect(Trading::Order::ItemType::ERC721_WITH_CRITERIA).to eq(4)
    end

    it 'defines ERC1155_WITH_CRITERIA as 5' do
      expect(Trading::Order::ItemType::ERC1155_WITH_CRITERIA).to eq(5)
    end
  end

  # ============================================
  # Off-chain Status Enum
  # ============================================
  describe 'offchain_status enum' do
    it 'defines active status' do
      order = build(:trading_order, offchain_status: :active)
      expect(order).to be_offchain_active
    end

    it 'defines over_matched status' do
      order = build(:trading_order, offchain_status: :over_matched)
      expect(order).to be_offchain_over_matched
    end

    it 'defines expired status' do
      order = build(:trading_order, offchain_status: :expired)
      expect(order).to be_offchain_expired
    end

    it 'defines paused status' do
      order = build(:trading_order, offchain_status: :paused)
      expect(order).to be_offchain_paused
    end

    it 'defines matching status' do
      order = build(:trading_order, offchain_status: :matching)
      expect(order).to be_offchain_matching
    end

    it 'defines closed status' do
      order = build(:trading_order, offchain_status: :closed)
      expect(order).to be_offchain_closed
    end

    it 'defines match_failed status' do
      order = build(:trading_order, offchain_status: :match_failed)
      expect(order).to be_offchain_match_failed
    end
  end

  # ============================================
  # Instance Methods
  # ============================================
  describe '#allows_partial_fill?' do
    it 'returns true for PARTIAL_RESTRICTED orders' do
      order = build(:trading_order, order_type: Trading::Order::OrderType::PARTIAL_RESTRICTED)
      expect(order.allows_partial_fill?).to be true
    end

    it 'returns false for FULL_RESTRICTED orders' do
      order = build(:trading_order, order_type: Trading::Order::OrderType::FULL_RESTRICTED)
      expect(order.allows_partial_fill?).to be false
    end
  end

  describe '#requires_full_fill?' do
    it 'returns true for FULL_RESTRICTED orders' do
      order = build(:trading_order, order_type: Trading::Order::OrderType::FULL_RESTRICTED)
      expect(order.requires_full_fill?).to be true
    end

    it 'returns false for PARTIAL_RESTRICTED orders' do
      order = build(:trading_order, order_type: Trading::Order::OrderType::PARTIAL_RESTRICTED)
      expect(order.requires_full_fill?).to be false
    end
  end

  describe '#order_type_description' do
    it 'returns description for FULL_RESTRICTED' do
      order = build(:trading_order, order_type: Trading::Order::OrderType::FULL_RESTRICTED)
      expect(order.order_type_description).to include('完全限制')
    end

    it 'returns description for PARTIAL_RESTRICTED' do
      order = build(:trading_order, order_type: Trading::Order::OrderType::PARTIAL_RESTRICTED)
      expect(order.order_type_description).to include('部分限制')
    end
  end

  describe '#contains_native_token?' do
    context 'for List orders' do
      let(:order) { build(:trading_order, :list) }

      it 'returns true when consideration uses native token' do
        order.consideration_item_type = Trading::Order::ItemType::NATIVE
        expect(order.contains_native_token?).to be true
      end

      it 'returns false when consideration uses ERC20' do
        order.consideration_item_type = Trading::Order::ItemType::ERC20
        expect(order.contains_native_token?).to be false
      end
    end

    context 'for Offer orders' do
      let(:order) { build(:trading_order, :offer) }

      it 'returns true when offer uses native token' do
        order.offer_item_type = Trading::Order::ItemType::NATIVE
        expect(order.contains_native_token?).to be true
      end

      it 'returns false when offer uses ERC20' do
        order.offer_item_type = Trading::Order::ItemType::ERC20
        expect(order.contains_native_token?).to be false
      end
    end
  end

  describe 'OrderStatusManager#set_offchain_status!' do
    let(:order) { create(:trading_order) }
    let(:manager) { Orders::OrderStatusManager.new(order) }

    it 'updates offchain_status' do
      manager.set_offchain_status!('paused', 'test reason')
      expect(order.reload.offchain_status).to eq('paused')
    end

    it 'sets offchain_status_reason' do
      manager.set_offchain_status!('paused', 'test reason')
      expect(order.reload.offchain_status_reason).to eq('test reason')
    end

    it 'updates offchain_status_updated_at' do
      original_time = order.offchain_status_updated_at
      sleep 0.01
      manager.set_offchain_status!('matching', nil)
      expect(order.reload.offchain_status_updated_at).not_to eq(original_time)
    end
  end

  describe '#should_display?' do
    it 'returns true for validated active orders' do
      order = build(:trading_order, onchain_status: 'validated', offchain_status: 'active')
      expect(order.should_display?).to be true
    end

    it 'returns true for partially_filled orders' do
      order = build(:trading_order, onchain_status: 'partially_filled', offchain_status: 'active')
      expect(order.should_display?).to be true
    end

    it 'returns false for filled orders' do
      order = build(:trading_order, onchain_status: 'filled')
      expect(order.should_display?).to be false
    end

    it 'returns false for cancelled orders' do
      order = build(:trading_order, onchain_status: 'cancelled')
      expect(order.should_display?).to be false
    end

    it 'returns false for expired offchain_status' do
      order = build(:trading_order, onchain_status: 'validated', offchain_status: 'expired')
      expect(order.should_display?).to be false
    end

    it 'returns false for paused offchain_status' do
      order = build(:trading_order, onchain_status: 'validated', offchain_status: 'paused')
      expect(order.should_display?).to be false
    end

    it 'returns true for matching offchain_status' do
      order = build(:trading_order, onchain_status: 'validated', offchain_status: 'matching')
      expect(order.should_display?).to be true
    end
  end

  describe '#status_priority' do
    it 'gives higher priority (lower number) to validated orders' do
      validated = build(:trading_order, onchain_status: 'validated', offchain_status: 'active')
      filled = build(:trading_order, onchain_status: 'filled', offchain_status: 'active')
      expect(validated.status_priority).to be < filled.status_priority
    end

    it 'adjusts priority based on offchain_status' do
      active = build(:trading_order, onchain_status: 'validated', offchain_status: 'active')
      paused = build(:trading_order, onchain_status: 'validated', offchain_status: 'paused')
      expect(active.status_priority).to be < paused.status_priority
    end
  end

  describe '#offchain_status_description' do
    it 'returns Chinese description for active' do
      order = build(:trading_order, offchain_status: 'active')
      expect(order.offchain_status_description).to eq('活跃')
    end

    it 'returns Chinese description for over_matched' do
      order = build(:trading_order, offchain_status: 'over_matched')
      expect(order.offchain_status_description).to eq('超额匹配')
    end

    it 'returns nil when offchain_status is blank' do
      order = build(:trading_order, offchain_status: nil)
      expect(order.offchain_status_description).to be_nil
    end
  end

  describe '#on_chain_status_description' do
    it 'returns Chinese description for validated' do
      order = build(:trading_order, onchain_status: 'validated')
      expect(order.on_chain_status_description).to eq('已验证')
    end

    it 'returns Chinese description for filled' do
      order = build(:trading_order, onchain_status: 'filled')
      expect(order.on_chain_status_description).to eq('已成交')
    end
  end

  describe '#combined_status_description' do
    it 'combines on-chain and off-chain descriptions' do
      order = build(:trading_order, onchain_status: 'validated', offchain_status: 'matching')
      expect(order.combined_status_description).to include('已验证')
      expect(order.combined_status_description).to include('撮合中')
    end

    it 'returns only on-chain description when offchain_status is blank' do
      order = build(:trading_order, onchain_status: 'validated', offchain_status: nil)
      expect(order.combined_status_description).to eq('已验证')
    end
  end

  # ============================================
  # Callbacks
  # ============================================
  describe 'callbacks' do
    describe 'after_commit :broadcast_depth_if_subscribed' do
      it 'broadcasts depth when there are subscribers' do
        allow(Realtime::SubscriptionGuard).to receive(:has_subscribers?).and_return(true)
        allow(Realtime::SubscriptionGuard).to receive(:depth_limits_for_market).and_return([5])

        expect(Jobs::Orders::DepthBroadcastJob).to receive(:perform_async).with('2800')
        create(:trading_order, market_id: '2800')
      end

      it 'does not broadcast when no subscribers' do
        allow(Redis.current).to receive(:keys).and_return([])

        expect(Jobs::Orders::DepthBroadcastJob).not_to receive(:perform_async)
        create(:trading_order, market_id: '2800')
      end
    end

    describe 'after_create :trigger_market_matching' do
      it 'triggers matching for validated orders' do
        allow(Redis.current).to receive(:get).and_return(nil)
        allow(Redis.current).to receive(:keys).and_return([])

        expect(Jobs::Matching::Worker).to receive(:perform_in).with(1.second, '2800', 'new_order')
        create(:trading_order, market_id: '2800', onchain_status: 'validated')
      end

      it 'does not trigger matching for pending orders' do
        expect(Jobs::Matching::Worker).not_to receive(:perform_in)
        create(:trading_order, market_id: '2800', onchain_status: 'pending')
      end

      it 'does not trigger matching for cancelled orders' do
        expect(Jobs::Matching::Worker).not_to receive(:perform_in)
        create(:trading_order, market_id: '2800', onchain_status: 'validated', is_cancelled: true)
      end

      it 'skips if recently triggered' do
        allow(Redis.current).to receive(:get).and_return(Time.current.to_f.to_s)
        allow(Redis.current).to receive(:keys).and_return([])

        expect(Jobs::Matching::Worker).not_to receive(:perform_in)
        create(:trading_order, market_id: '2800', onchain_status: 'validated')
      end
    end
  end
end
