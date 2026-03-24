# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Partial Fill Remainder Logic', type: :service do
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

  describe Matching::Engine do
    let(:market_id) { 'test-market-1' }
    let(:strategy) { described_class.new(market_id) }

    describe '#should_use_greedy_algorithm' do
      it 'returns true for PARTIAL_RESTRICTED orders' do
        order = build(:trading_order, order_type: Trading::Order::OrderType::PARTIAL_RESTRICTED)
        result = strategy.should_use_greedy_algorithm(order, 5, [])
        expect(result).to be true
      end

      it 'returns false for FULL_RESTRICTED orders' do
        order = build(:trading_order, order_type: Trading::Order::OrderType::FULL_RESTRICTED)
        result = strategy.should_use_greedy_algorithm(order, 5, [])
        expect(result).to be false
      end

      it 'returns false when bid_order is nil' do
        result = strategy.should_use_greedy_algorithm(nil, 5, [])
        expect(result).to be false
      end
    end

    describe '#find_optimal_combination_greedy' do
      # asks format: [price, qty, hash, identifier, created_at]
      let(:now) { Time.current }

      def make_ask(price:, qty:, hash: nil, identifier: nil)
        hash ||= "0x#{SecureRandom.hex(32)}"
        identifier ||= '1048833'
        [price, qty.to_s, hash, identifier, now]
      end

      context 'when asks exactly fill target' do
        it 'returns match_completed: true with remaining_qty: 0' do
          asks = [
            make_ask(price: 100, qty: 2),
            make_ask(price: 100, qty: 3)
          ]
          result = strategy.find_optimal_combination_greedy(5, asks)

          expect(result[:match_completed]).to be true
          expect(result[:remaining_qty]).to eq(0)
          expect(result[:matched_qty]).to eq(5)
          expect(result[:current_orders].length).to eq(2)
        end
      end

      context 'when asks are insufficient' do
        it 'returns partial_match: true with remaining_qty > 0' do
          asks = [
            make_ask(price: 100, qty: 1),
            make_ask(price: 100, qty: 1),
            make_ask(price: 100, qty: 1)
          ]
          result = strategy.find_optimal_combination_greedy(5, asks)

          expect(result[:match_completed]).to be false
          expect(result[:remaining_qty]).to eq(2)
          expect(result[:matched_qty]).to eq(3)
          expect(result[:partial_match]).to be true
          expect(result[:current_orders].length).to eq(3)
        end
      end

      context 'when a single ask is larger than remaining' do
        it 'partially consumes the ask and returns remaining_qty: 0' do
          asks = [
            make_ask(price: 100, qty: 3),
            make_ask(price: 100, qty: 10) # larger than remaining 2
          ]
          result = strategy.find_optimal_combination_greedy(5, asks)

          # First ask fully consumed (3), second partially consumed (2)
          expect(result[:remaining_qty]).to eq(0)
          expect(result[:matched_qty]).to eq(5)
          expect(result[:current_orders].length).to eq(2)
          expect(result[:partial_match]).to be true
        end
      end

      context 'when target_qty is 0' do
        it 'returns immediately with match_completed: true' do
          result = strategy.find_optimal_combination_greedy(0, [make_ask(price: 100, qty: 1)])

          expect(result[:match_completed]).to be true
          expect(result[:remaining_qty]).to eq(0)
        end
      end

      context 'when asks array is empty' do
        it 'returns match_completed: false with full remaining' do
          result = strategy.find_optimal_combination_greedy(5, [])

          expect(result[:match_completed]).to be false
          expect(result[:remaining_qty]).to eq(5)
        end
      end

      context 'price-time priority ordering' do
        it 'sorts asks by price first, then created_at' do
          older = now - 1.hour
          newer = now

          ask_expensive = make_ask(price: 200, qty: 1)
          ask_cheap_old = [100, '1', "0x#{'a' * 64}", '1048833', older]
          ask_cheap_new = [100, '1', "0x#{'b' * 64}", '1048833', newer]

          result = strategy.find_optimal_combination_greedy(2, [ask_expensive, ask_cheap_old, ask_cheap_new])

          # Should pick the two cheapest (both price 100), older first
          expect(result[:current_orders]).to eq(["0x#{'a' * 64}", "0x#{'b' * 64}"])
          expect(result[:matched_qty]).to eq(2)
        end
      end

      context 'remainder scenario (历史部分成交订单再次 match)' do
        it 'Round 1: partial fill 3/5, Round 2: fill remaining 2/5' do
          # Round 1: Buy(qty=5) vs 3 sells(qty=1)
          sells_r1 = Array.new(3) { |i| make_ask(price: 100, qty: 1, hash: "0x#{i.to_s * 64}") }
          r1 = strategy.find_optimal_combination_greedy(5, sells_r1)

          expect(r1[:matched_qty]).to eq(3)
          expect(r1[:remaining_qty]).to eq(2)
          expect(r1[:partial_match]).to be true

          # Round 2: remaining buy(qty=2) vs 2 new sells(qty=1)
          sells_r2 = Array.new(2) { |i| make_ask(price: 100, qty: 1, hash: "0x#{(i + 3).to_s * 64}") }
          r2 = strategy.find_optimal_combination_greedy(r1[:remaining_qty], sells_r2)

          expect(r2[:matched_qty]).to eq(2)
          expect(r2[:remaining_qty]).to eq(0)
          expect(r2[:match_completed]).to be true
        end
      end
    end
  end

  describe Matching::Selection::ExactFillSolver do
    describe '#solve' do
      context 'when exact match exists' do
        it 'finds combination that sums to target' do
          asks = [
            [100, '2', "0x#{'a' * 64}", '1048833', Time.current],
            [100, '3', "0x#{'b' * 64}", '1048833', Time.current],
            [100, '5', "0x#{'c' * 64}", '1048833', Time.current]
          ]
          solver = described_class.new(target_qty: 5, asks: asks)
          result = solver.solve

          expect(result[:match_completed]).to be true
          expect(result[:remaining_qty]).to eq(0)
          expect(result[:matched_qty]).to eq(5)
          # Could be [a,b] or [c] — either is valid
          expect(result[:current_orders]).not_to be_empty
        end
      end

      context 'when no exact match exists' do
        it 'returns no match (does NOT return partial)' do
          asks = [
            [100, '2', "0x#{'a' * 64}", '1048833', Time.current],
            [100, '4', "0x#{'b' * 64}", '1048833', Time.current]
          ]
          solver = described_class.new(target_qty: 5, asks: asks)
          result = solver.solve

          expect(result[:match_completed]).to be false
          expect(result[:remaining_qty]).to eq(5)
          expect(result[:matched_qty]).to eq(0)
          expect(result[:current_orders]).to be_empty
        end
      end

      context 'when asks array is empty' do
        it 'returns no match' do
          solver = described_class.new(target_qty: 5, asks: [])
          result = solver.solve

          expect(result[:match_completed]).to be false
          expect(result[:current_orders]).to be_empty
        end
      end

      context 'when target_qty is 0' do
        it 'returns exact match immediately' do
          solver = described_class.new(target_qty: 0, asks: [[100, '1', '0xhash', '1048833', Time.current]])
          result = solver.solve

          expect(result[:match_completed]).to be true
          expect(result[:matched_qty]).to eq(0)
          expect(result[:remaining_qty]).to eq(0)
        end
      end

      context 'when total ask qty is less than target' do
        it 'returns no match immediately (optimization)' do
          asks = [
            [100, '1', "0x#{'a' * 64}", '1048833', Time.current],
            [100, '2', "0x#{'b' * 64}", '1048833', Time.current]
          ]
          solver = described_class.new(target_qty: 10, asks: asks)
          result = solver.solve

          expect(result[:match_completed]).to be false
          expect(result[:remaining_qty]).to eq(10)
        end
      end

      context 'scale_factor' do
        it 'defaults to 1 when invalid value given' do
          solver = described_class.new(target_qty: 3, asks: [
            [100, '3', "0x#{'a' * 64}", '1048833', Time.current]
          ], scale_factor: 0)
          result = solver.solve
          expect(result[:match_completed]).to be true
        end

        it 'handles negative scale_factor gracefully' do
          solver = described_class.new(target_qty: 3, asks: [
            [100, '3', "0x#{'a' * 64}", '1048833', Time.current]
          ], scale_factor: -1)
          result = solver.solve
          expect(result[:match_completed]).to be true
        end
      end

      context 'FULL_RESTRICTED vs PARTIAL_RESTRICTED behavior contrast' do
        let(:asks) do
          Array.new(3) do |i|
            [100, '1', "0x#{i.to_s.rjust(64, '0')}", '1048833', Time.current]
          end
        end

        it 'ExactFillSolver finds exact match for qty=3 with 3x qty=1 asks' do
          solver = described_class.new(target_qty: 3, asks: asks)
          result = solver.solve

          expect(result[:match_completed]).to be true
          expect(result[:matched_qty]).to eq(3)
        end

        it 'ExactFillSolver finds NO match for qty=5 with 3x qty=1 asks' do
          solver = described_class.new(target_qty: 5, asks: asks)
          result = solver.solve

          expect(result[:match_completed]).to be false
          expect(result[:current_orders]).to be_empty
        end
      end
    end
  end
end
