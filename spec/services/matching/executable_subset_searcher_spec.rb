# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Matching::Selection::ExecutableSubsetSearcher, type: :service do
  describe '#call' do
    it 'finds a feasible 2v3 subset for asks(4,6) and bids(2,3,5)' do
      now = Time.current
      bids = [
        { price: 100, qty: 2, hash: 'bid_2', created_at: now },
        { price: 100, qty: 3, hash: 'bid_3', created_at: now + 1 },
        { price: 100, qty: 5, hash: 'bid_5', created_at: now + 2 }
      ]
      asks = [
        { price: 90, qty: 4, hash: 'ask_4', created_at: now },
        { price: 90, qty: 6, hash: 'ask_6', created_at: now + 1 }
      ]

      result = described_class.new(bids: bids, asks: asks).call

      expect(result[:feasible]).to be true
      expect(result[:target_qty]).to eq(10)
      expect(result[:selected_bid_hashes].sort).to eq(%w[bid_2 bid_3 bid_5].sort)
      expect(result[:selected_ask_hashes].sort).to eq(%w[ask_4 ask_6].sort)
      expect(result[:flows].sum { |flow| flow[:qty] }).to be_within(1e-9).of(10)
    end

    it 'ignores incompatible noise and still returns a feasible subset' do
      now = Time.current
      bids = [
        { price: 100, qty: 5, hash: 'bid_5', created_at: now },
        { price: 10, qty: 9, hash: 'noise_bid', created_at: now + 1 }
      ]
      asks = [
        { price: 90, qty: 5, hash: 'ask_5', created_at: now },
        { price: 999, qty: 9, hash: 'noise_ask', created_at: now + 1 }
      ]

      result = described_class.new(bids: bids, asks: asks).call

      expect(result[:feasible]).to be true
      expect(result[:target_qty]).to eq(5)
      expect(result[:selected_bid_hashes]).to eq(['bid_5'])
      expect(result[:selected_ask_hashes]).to eq(['ask_5'])
      expect(result[:flows].sum { |flow| flow[:qty] }).to be_within(1e-9).of(5)
    end

    it 'returns no_compatible_edges when no price-compatible pairs exist' do
      bids = [{ price: 10, qty: 5, hash: 'bid_5', created_at: Time.current }]
      asks = [{ price: 90, qty: 5, hash: 'ask_5', created_at: Time.current }]

      result = described_class.new(bids: bids, asks: asks).call

      expect(result[:feasible]).to be false
      expect(result[:exit_reason]).to eq('no_compatible_edges')
      expect(result[:flows]).to eq([])
    end
  end
end
