# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Matching::Selection::ExactFillSolver, type: :service do
  describe '#solve' do
    it 'returns exact matched orders when a solution exists' do
      asks = [
        [100, 3, 'hash1', 'token_1', Time.current],
        [101, 5, 'hash2', 'token_1', Time.current],
        [102, 2, 'hash3', 'token_1', Time.current]
      ]

      result = described_class.new(target_qty: 7, asks: asks).solve

      expect(result[:match_completed]).to be true
      expect(result[:current_orders].sort).to eq(%w[hash2 hash3].sort)
      expect(result[:remaining_qty]).to eq(0)
    end

    it 'returns no match when no exact solution exists' do
      asks = [
        [100, 3, 'hash1', 'token_1', Time.current],
        [101, 5, 'hash2', 'token_1', Time.current],
        [102, 2, 'hash3', 'token_1', Time.current]
      ]

      result = described_class.new(target_qty: 4, asks: asks).solve

      expect(result[:match_completed]).to be false
      expect(result[:current_orders]).to be_empty
      expect(result[:remaining_qty]).to eq(4.0)
    end

    it 'returns no match when target exceeds total asks' do
      asks = [
        [100, 3, 'hash1', 'token_1', Time.current],
        [101, 5, 'hash2', 'token_1', Time.current]
      ]

      result = described_class.new(target_qty: 20, asks: asks).solve

      expect(result[:match_completed]).to be false
      expect(result[:current_orders]).to be_empty
      expect(result[:remaining_qty]).to eq(20.0)
    end

    it 'returns success with empty selection when target is zero' do
      asks = [[100, 3, 'hash1', 'token_1', Time.current]]

      result = described_class.new(target_qty: 0, asks: asks).solve

      expect(result[:match_completed]).to be true
      expect(result[:current_orders]).to be_empty
      expect(result[:remaining_qty]).to eq(0)
    end

    it 'ignores non-positive asks and still finds exact solution' do
      asks = [
        [100, 0, 'hash0', 'token_1', Time.current],
        [101, -1, 'hash_negative', 'token_1', Time.current],
        [102, 2, 'hash2', 'token_1', Time.current],
        [103, 5, 'hash5', 'token_1', Time.current]
      ]

      result = described_class.new(target_qty: 7, asks: asks).solve

      expect(result[:match_completed]).to be true
      expect(result[:current_orders].sort).to eq(%w[hash2 hash5].sort)
      expect(result[:remaining_qty]).to eq(0)
    end
  end
end
