# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Trading::Order, 'partial fill behavior', type: :model do
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

  describe '#allows_partial_fill?' do
    it 'returns true for PARTIAL_RESTRICTED (3)' do
      order = build(:trading_order, order_type: Trading::Order::OrderType::PARTIAL_RESTRICTED)
      expect(order.allows_partial_fill?).to be true
    end

    it 'returns true for PARTIAL_OPEN (1)' do
      # PARTIAL_OPEN is not ALLOWED by platform validation,
      # but the method itself should return true for its logic
      order = build(:trading_order)
      order.order_type = Trading::Order::OrderType::PARTIAL_OPEN
      expect(order.allows_partial_fill?).to be true
    end

    it 'returns false for FULL_RESTRICTED (2)' do
      order = build(:trading_order, order_type: Trading::Order::OrderType::FULL_RESTRICTED)
      expect(order.allows_partial_fill?).to be false
    end

    it 'returns false for FULL_OPEN (0)' do
      order = build(:trading_order)
      order.order_type = Trading::Order::OrderType::FULL_OPEN
      expect(order.allows_partial_fill?).to be false
    end

    it 'returns false for CONTRACT (4)' do
      order = build(:trading_order)
      order.order_type = Trading::Order::OrderType::CONTRACT
      expect(order.allows_partial_fill?).to be false
    end
  end

  describe '#requires_full_fill?' do
    it 'returns true only for FULL_RESTRICTED (2)' do
      order = build(:trading_order, order_type: Trading::Order::OrderType::FULL_RESTRICTED)
      expect(order.requires_full_fill?).to be true
    end

    it 'returns false for PARTIAL_RESTRICTED (3)' do
      order = build(:trading_order, order_type: Trading::Order::OrderType::PARTIAL_RESTRICTED)
      expect(order.requires_full_fill?).to be false
    end

    it 'returns false for FULL_OPEN (0)' do
      order = build(:trading_order)
      order.order_type = Trading::Order::OrderType::FULL_OPEN
      expect(order.requires_full_fill?).to be false
    end

    it 'returns false for PARTIAL_OPEN (1)' do
      order = build(:trading_order)
      order.order_type = Trading::Order::OrderType::PARTIAL_OPEN
      expect(order.requires_full_fill?).to be false
    end
  end

  describe 'platform allowed order types' do
    it 'allows FULL_RESTRICTED' do
      order = build(:trading_order, order_type: Trading::Order::OrderType::FULL_RESTRICTED)
      expect(order).to be_valid
    end

    it 'allows PARTIAL_RESTRICTED' do
      order = build(:trading_order, order_type: Trading::Order::OrderType::PARTIAL_RESTRICTED)
      expect(order).to be_valid
    end

    it 'rejects FULL_OPEN' do
      order = build(:trading_order, order_type: Trading::Order::OrderType::FULL_OPEN)
      expect(order).not_to be_valid
      expect(order.errors[:order_type]).not_to be_empty
    end

    it 'rejects PARTIAL_OPEN' do
      order = build(:trading_order, order_type: Trading::Order::OrderType::PARTIAL_OPEN)
      expect(order).not_to be_valid
    end

    it 'rejects CONTRACT' do
      order = build(:trading_order, order_type: Trading::Order::OrderType::CONTRACT)
      expect(order).not_to be_valid
    end
  end

  describe 'ALLOWED_ORDER_TYPES constant' do
    it 'contains exactly FULL_RESTRICTED and PARTIAL_RESTRICTED' do
      expect(Trading::Order::ALLOWED_ORDER_TYPES).to contain_exactly(
        Trading::Order::OrderType::FULL_RESTRICTED,
        Trading::Order::OrderType::PARTIAL_RESTRICTED
      )
    end

    it 'is frozen' do
      expect(Trading::Order::ALLOWED_ORDER_TYPES).to be_frozen
    end
  end

  describe 'default order_type from database' do
    it 'defaults to PARTIAL_RESTRICTED (3)' do
      order = create(:trading_order)
      expect(order.order_type).to eq(Trading::Order::OrderType::PARTIAL_RESTRICTED)
    end
  end

  describe '#order_type_description' do
    it 'returns meaningful description for FULL_RESTRICTED' do
      order = build(:trading_order, order_type: Trading::Order::OrderType::FULL_RESTRICTED)
      expect(order.order_type_description).to include('完全限制')
      expect(order.order_type_description).to include('必须全部成交')
    end

    it 'returns meaningful description for PARTIAL_RESTRICTED' do
      order = build(:trading_order, order_type: Trading::Order::OrderType::PARTIAL_RESTRICTED)
      expect(order.order_type_description).to include('部分限制')
      expect(order.order_type_description).to include('允许部分成交')
    end

    it 'returns fallback for unknown type' do
      order = build(:trading_order)
      order.order_type = 99
      expect(order.order_type_description).to include('未知类型')
    end
  end
end
