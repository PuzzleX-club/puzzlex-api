# frozen_string_literal: true

require 'rails_helper'

RSpec.describe MarketData::KlineBuilder do
  include ServiceTestHelpers

  let(:market_id) { 101 }
  let(:interval) { 60 } # 1 minute
  let(:now) { Time.current.to_i }
  let(:aligned_time) { (now / interval) * interval }
  let(:start_time) { aligned_time - interval }
  let(:end_time) { aligned_time }

  before do
    stub_redis
    stub_action_cable
  end

  describe '.build' do
    context 'with no fills' do
      before do
        # Mock for fetch_fills
        order_fill_relation = double('OrderFill::ActiveRecord_Relation')
        allow(Trading::OrderFill).to receive(:where).and_return(order_fill_relation)
        allow(order_fill_relation).to receive(:where).and_return(order_fill_relation)
        allow(order_fill_relation).to receive(:order).and_return(order_fill_relation)
        allow(order_fill_relation).to receive(:includes).and_return([])
        allow(order_fill_relation).to receive(:first).and_return(nil)

        # Mock for fetch_previous_close
        kline_relation = double('Kline::ActiveRecord_Relation')
        allow(Trading::Kline).to receive(:where).and_return(kline_relation)
        allow(kline_relation).to receive(:where).and_return(kline_relation)
        allow(kline_relation).to receive(:order).and_return(kline_relation)
        allow(kline_relation).to receive(:limit).and_return(kline_relation)
        allow(kline_relation).to receive(:first).and_return(nil)
      end

      it 'returns empty kline with default price' do
        result = described_class.build(market_id, interval, start_time, end_time)

        expect(result).to be_an(Array)
        expect(result.length).to eq(7)
        expect(result[0]).to eq(end_time) # timestamp
        expect(result[5]).to eq('0') # volume
      end
    end

    context 'with fills data' do
      let(:fills) do
        [
          create_fill_double(price: 100, amount: 10, timestamp: start_time + 10),
          create_fill_double(price: 110, amount: 5, timestamp: start_time + 30),
          create_fill_double(price: 105, amount: 8, timestamp: start_time + 50)
        ]
      end

      before do
        order_fill_relation = double('OrderFill::ActiveRecord_Relation')
        allow(Trading::OrderFill).to receive(:where).with(market_id: market_id).and_return(order_fill_relation)
        allow(order_fill_relation).to receive(:where).and_return(order_fill_relation)
        allow(order_fill_relation).to receive(:order).and_return(order_fill_relation)
        allow(order_fill_relation).to receive(:includes).and_return(fills)

        allow(MarketData::PriceCalculator).to receive(:calculate_price_from_fill) do |fill|
          fill.price.to_i
        end
      end

      it 'calculates OHLC from fills' do
        result = described_class.build(market_id, interval, start_time, end_time)

        expect(result).to be_an(Array)
        expect(result[0]).to eq(end_time) # timestamp
        expect(result[1]).to eq(100) # open (first price)
        expect(result[2]).to eq(110) # high
        expect(result[3]).to eq(100) # low
        expect(result[4]).to eq(105) # close (last price)
      end

      it 'calculates total volume' do
        result = described_class.build(market_id, interval, start_time, end_time)

        # Total volume: 10 + 5 + 8 = 23
        expect(result[5].to_f).to eq(23.0)
      end
    end
  end

  describe '.batch_build' do
    let(:requests) do
      [
        { market_id: 101, interval: 60, start_time: start_time, end_time: end_time },
        { market_id: 102, interval: 300, start_time: start_time, end_time: end_time }
      ]
    end

    before do
      allow(described_class).to receive(:build).and_return([end_time, 100, 100, 100, 100, '0', 0])
    end

    it 'returns hash with results keyed by market_id:interval' do
      result = described_class.batch_build(requests)

      expect(result).to be_a(Hash)
      expect(result.keys).to include('101:60', '102:300')
    end

    it 'calls build for each request' do
      described_class.batch_build(requests)

      expect(described_class).to have_received(:build).twice
    end
  end

  describe '.build_realtime' do
    before do
      allow(Time).to receive(:current).and_return(Time.at(now))

      order_fill_relation = double('OrderFill::ActiveRecord_Relation')
      allow(Trading::OrderFill).to receive(:where).and_return(order_fill_relation)
      allow(order_fill_relation).to receive(:where).and_return(order_fill_relation)
      allow(order_fill_relation).to receive(:order).and_return(order_fill_relation)
      allow(order_fill_relation).to receive(:includes).and_return([])
      allow(order_fill_relation).to receive(:first).and_return(nil)

      kline_relation = double('Kline::ActiveRecord_Relation')
      allow(Trading::Kline).to receive(:where).and_return(kline_relation)
      allow(kline_relation).to receive(:where).and_return(kline_relation)
      allow(kline_relation).to receive(:order).and_return(kline_relation)
      allow(kline_relation).to receive(:limit).and_return(kline_relation)
      allow(kline_relation).to receive(:first).and_return(nil)
    end

    it 'aligns time to interval boundary' do
      result = described_class.build_realtime(market_id, interval)

      # The timestamp should be aligned to the interval
      expect(result[0] % interval).to eq(0)
    end

    it 'returns kline array format' do
      result = described_class.build_realtime(market_id, interval)

      expect(result).to be_an(Array)
      expect(result.length).to eq(7)
    end
  end

  describe '.build_with_previous' do
    let(:previous_kline_record) do
      double(
        'Kline',
        open: 100,
        high: 110,
        low: 95,
        close: 105,
        volume: BigDecimal('50'),
        turnover: BigDecimal('5250')
      )
    end

    before do
      allow(Time).to receive(:current).and_return(Time.at(now))
      allow(described_class).to receive(:build_realtime).and_return([aligned_time, 105, 112, 103, 108, '30', '3180'])

      kline_relation = double('Kline::ActiveRecord_Relation')
      allow(Trading::Kline).to receive(:where).and_return(kline_relation)
      allow(kline_relation).to receive(:where).and_return(kline_relation)
      allow(kline_relation).to receive(:first).and_return(previous_kline_record)
    end

    it 'returns hash with current and previous klines' do
      result = described_class.build_with_previous(market_id, interval)

      expect(result).to be_a(Hash)
      expect(result).to have_key(:current)
      expect(result).to have_key(:previous)
    end

    it 'marks current kline as not final' do
      result = described_class.build_with_previous(market_id, interval)

      expect(result[:current][:is_final]).to be false
    end

    it 'includes previous kline data when available' do
      result = described_class.build_with_previous(market_id, interval)

      expect(result[:previous]).not_to be_nil
      expect(result[:previous][:is_final]).to be true
      expect(result[:previous][:open]).to eq(100)
      expect(result[:previous][:close]).to eq(105)
    end

    context 'when no previous kline exists' do
      before do
        kline_relation = double('Kline::ActiveRecord_Relation')
        allow(Trading::Kline).to receive(:where).and_return(kline_relation)
        allow(kline_relation).to receive(:where).and_return(kline_relation)
        allow(kline_relation).to receive(:first).and_return(nil)
      end

      it 'returns nil for previous' do
        result = described_class.build_with_previous(market_id, interval)

        expect(result[:previous]).to be_nil
      end
    end
  end

  describe 'private methods' do
    describe '.align_to_interval' do
      it 'aligns timestamp to interval boundary' do
        timestamp = 1700000000 + 45 # Some offset
        aligned = described_class.send(:align_to_interval, timestamp, 60)

        expect(aligned % 60).to eq(0)
        expect(aligned).to be <= timestamp
      end

      it 'handles different intervals correctly' do
        timestamp = 1700000123

        # 1 minute interval
        expect(described_class.send(:align_to_interval, timestamp, 60) % 60).to eq(0)

        # 5 minute interval
        expect(described_class.send(:align_to_interval, timestamp, 300) % 300).to eq(0)

        # 1 hour interval
        expect(described_class.send(:align_to_interval, timestamp, 3600) % 3600).to eq(0)
      end
    end

    describe '.build_empty_kline' do
      it 'creates kline with all values set to default price' do
        result = described_class.send(:build_empty_kline, end_time, 100)

        expect(result[0]).to eq(end_time) # timestamp
        expect(result[1]).to eq(100) # open
        expect(result[2]).to eq(100) # high
        expect(result[3]).to eq(100) # low
        expect(result[4]).to eq(100) # close
        expect(result[5]).to eq('0') # volume
        expect(result[6]).to eq(0) # turnover
      end

      it 'handles zero default price' do
        result = described_class.send(:build_empty_kline, end_time, 0)

        expect(result[1]).to eq(0)
        expect(result[2]).to eq(0)
        expect(result[3]).to eq(0)
        expect(result[4]).to eq(0)
      end

      it 'handles string price input' do
        result = described_class.send(:build_empty_kline, end_time, '150')

        expect(result[1]).to eq(150)
      end
    end
  end

  private

  def create_fill_double(price:, amount:, timestamp:)
    double(
      'OrderFill',
      price: price.to_s,
      filled_amount: amount.to_s,
      block_timestamp: timestamp,
      order: double('Order', price: price.to_s)
    )
  end
end
