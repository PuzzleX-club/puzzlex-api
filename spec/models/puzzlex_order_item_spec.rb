# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Trading::OrderItem, type: :model do
  subject { build(:trading_order_item) }

  before do
    # Global stubs in spec/support/global_external_stubs.rb handle Redis/ActionCable/Sidekiq
  end

  # ============================================
  # Factory Tests
  # ============================================
  describe 'factory' do
    it 'has a valid factory' do
      expect(build(:trading_order_item)).to be_valid
    end

    it 'can be persisted' do
      item = create(:trading_order_item)
      expect(item).to be_persisted
      expect(item.token_address).to be_present
    end

    it 'creates offer role item by default' do
      item = build(:trading_order_item)
      expect(item.role).to eq('offer')
    end

    it 'creates consideration role with :consideration_item trait' do
      item = build(:trading_order_item, :consideration_item)
      expect(item.role).to eq('consideration')
    end
  end

  # ============================================
  # Associations
  # ============================================
  describe 'associations' do
    it { is_expected.to belong_to(:order).class_name('Trading::Order') }
  end

  # ============================================
  # Validations
  # ============================================
  describe 'validations' do
    it { is_expected.to validate_presence_of(:role) }
    it { is_expected.to validate_inclusion_of(:role).in_array(%w[offer consideration]) }
    it { is_expected.to validate_presence_of(:token_address) }
    it { is_expected.to validate_numericality_of(:start_amount).is_greater_than_or_equal_to(0) }
    it { is_expected.to validate_numericality_of(:end_amount).is_greater_than_or_equal_to(0) }

    it 'is invalid with invalid role' do
      item = build(:trading_order_item, role: 'invalid')
      expect(item).not_to be_valid
      expect(item.errors[:role]).to be_present
    end

    it 'is invalid without token_address' do
      item = build(:trading_order_item, token_address: nil)
      expect(item).not_to be_valid
    end

    it 'is invalid with negative start_amount' do
      item = build(:trading_order_item, start_amount: -1)
      expect(item).not_to be_valid
    end

    it 'is invalid with negative end_amount' do
      item = build(:trading_order_item, end_amount: -1)
      expect(item).not_to be_valid
    end
  end

  # ============================================
  # Instance Methods
  # ============================================
  describe '#amount_at_progress' do
    let(:item) do
      build(:trading_order_item,
            start_amount: 100,
            end_amount: 200)
    end

    it 'returns start_amount at progress 0' do
      expect(item.amount_at_progress(0)).to eq(100)
    end

    it 'returns end_amount at progress 1' do
      expect(item.amount_at_progress(1)).to eq(200)
    end

    it 'returns interpolated value at progress 0.5' do
      expect(item.amount_at_progress(0.5)).to eq(150)
    end

    it 'handles same start and end amounts' do
      item.start_amount = 100
      item.end_amount = 100
      expect(item.amount_at_progress(0.5)).to eq(100)
    end
  end

  describe '#price_distribution_at_progress' do
    let(:item) do
      build(:trading_order_item,
            start_price_distribution: start_dist,
            end_price_distribution: end_dist)
    end

    let(:start_dist) do
      [
        {
          'token_address' => '0xToken1',
          'item_type' => 3,
          'token_id' => '12345',
          'recipients' => [
            { 'address' => '0xSeller', 'amount' => '100' },
            { 'address' => '0xRoyalty', 'amount' => '10' }
          ]
        }
      ]
    end

    let(:end_dist) do
      [
        {
          'token_address' => '0xToken1',
          'item_type' => 3,
          'token_id' => '12345',
          'recipients' => [
            { 'address' => '0xSeller', 'amount' => '200' },
            { 'address' => '0xRoyalty', 'amount' => '20' }
          ]
        }
      ]
    end

    it 'returns start distribution at progress 0' do
      result = item.price_distribution_at_progress(0)
      expect(result.first['recipients'].first['amount']).to eq('100.0')
    end

    it 'returns end distribution at progress 1' do
      result = item.price_distribution_at_progress(1)
      expect(result.first['recipients'].first['amount']).to eq('200.0')
    end

    it 'returns interpolated distribution at progress 0.5' do
      result = item.price_distribution_at_progress(0.5)
      expect(result.first['recipients'].first['amount']).to eq('150.0')
    end

    it 'preserves token metadata' do
      result = item.price_distribution_at_progress(0.5)
      expect(result.first['token_address']).to eq('0xToken1')
      expect(result.first['item_type']).to eq(3)
      expect(result.first['token_id']).to eq('12345')
    end

    it 'interpolates multiple recipients' do
      result = item.price_distribution_at_progress(0.5)
      seller = result.first['recipients'].find { |r| r['address'] == '0xSeller' }
      royalty = result.first['recipients'].find { |r| r['address'] == '0xRoyalty' }

      expect(seller['amount']).to eq('150.0')
      expect(royalty['amount']).to eq('15.0')
    end

    context 'with empty distributions' do
      let(:start_dist) { [] }
      let(:end_dist) { [] }

      it 'returns empty array' do
        result = item.price_distribution_at_progress(0.5)
        expect(result).to eq([])
      end
    end

    context 'with mismatched token entries' do
      let(:end_dist) do
        [
          {
            'token_address' => '0xDifferentToken',
            'item_type' => 3,
            'token_id' => '99999',
            'recipients' => [
              { 'address' => '0xSeller', 'amount' => '200' }
            ]
          }
        ]
      end

      it 'skips entries without matching end distribution' do
        result = item.price_distribution_at_progress(0.5)
        expect(result).to eq([])
      end
    end
  end

  # ============================================
  # Token ID Format Tests
  # ============================================
  describe 'token_id format' do
    it 'uses structured token ID from factory' do
      item = create(:trading_order_item)
      token_id = item.token_id.to_i

      # Verify it's not a simple ID like 1, 2, 3
      expect(token_id).to be > 1000
    end

    it 'maintains token_id structure across items' do
      item1 = create(:trading_order_item)
      item2 = create(:trading_order_item)

      # Both should have structured IDs (> 1000)
      expect(item1.token_id.to_i).to be > 1000
      expect(item2.token_id.to_i).to be > 1000

      # Should be different due to sequence
      expect(item1.token_id).not_to eq(item2.token_id)
    end
  end
end
