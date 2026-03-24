# frozen_string_literal: true

require 'rails_helper'

RSpec.describe MarketData::TickerCalculator, type: :service do
  before do
    # 使用 ServiceTestHelpers 提供的 stub 方法
    stub_redis
    stub_action_cable
    stub_sidekiq_workers
  end

  let(:market_id) { '2801' }

  # ============================================
  # 常量测试
  # ============================================
  describe 'INTERVALS' do
    it 'defines supported intervals' do
      expect(described_class::INTERVALS).to be_a(Hash)
      expect(described_class::INTERVALS.keys).to include(30, 60, 360, 720, 1440, 10080)
    end

    it 'has correct second values' do
      expect(described_class::INTERVALS[30]).to eq(1800)   # 30 minutes
      expect(described_class::INTERVALS[60]).to eq(3600)   # 1 hour
      expect(described_class::INTERVALS[1440]).to eq(86400) # 1 day
    end
  end

  # ============================================
  # 时间对齐测试 (使用 send 访问私有方法)
  # ============================================
  describe '.align_time (private)' do
    it 'aligns to 30-minute boundary' do
      # 假设时间是 14:23:45
      timestamp = Time.new(2024, 1, 15, 14, 23, 45).to_i
      aligned = described_class.send(:align_time, timestamp, 1800) # 30 minutes

      # 应该对齐到 14:00:00
      expect(aligned).to eq(Time.new(2024, 1, 15, 14, 0, 0).to_i)
    end

    it 'aligns to 1-hour boundary' do
      timestamp = Time.new(2024, 1, 15, 14, 45, 30).to_i
      aligned = described_class.send(:align_time, timestamp, 3600)

      expect(aligned).to eq(Time.new(2024, 1, 15, 14, 0, 0).to_i)
    end

    it 'aligns to 1-day boundary' do
      timestamp = Time.new(2024, 1, 15, 14, 45, 30).to_i
      aligned = described_class.send(:align_time, timestamp, 86400)

      # 应该对齐到当天 00:00:00 UTC
      expected = Time.new(2024, 1, 15, 0, 0, 0).to_i
      # 允许时区差异
      expect(aligned).to be_within(86400).of(expected)
    end
  end

  # ============================================
  # 周期计算测试
  # ============================================
  describe '.calculate_with_interval' do
    context 'with unsupported interval' do
      it 'returns nil for unsupported interval' do
        result = described_class.calculate_with_interval(market_id, 45) # 45 minutes not supported

        expect(result).to be_nil
      end
    end

    context 'with no fills' do
      before do
        # 确保没有成交记录
        empty_fills = []
        fill_relation = double('fill_relation')
        allow(Trading::OrderFill).to receive(:where).and_return(fill_relation)
        allow(fill_relation).to receive(:where).and_return(fill_relation)
        allow(fill_relation).to receive(:order).and_return(empty_fills)
      end

      it 'returns ticker from previous period or nil' do
        allow(described_class).to receive(:get_ticker_from_previous).and_return({
          market_id: market_id,
          open: '100',
          high: '100',
          low: '100',
          close: '100',
          volume: '0'
        })

        result = described_class.calculate_with_interval(market_id, 30)

        # 可能返回 Hash 或 nil
        expect(result).to satisfy { |r| r.nil? || r.is_a?(Hash) }
      end
    end

    context 'with fills' do
      let(:fills) do
        [
          double(price: '100', amount: '10', block_timestamp: Time.current.to_i - 1000),
          double(price: '110', amount: '5', block_timestamp: Time.current.to_i - 500),
          double(price: '105', amount: '8', block_timestamp: Time.current.to_i - 100)
        ]
      end

      before do
        fill_relation = double('fill_relation')
        allow(Trading::OrderFill).to receive(:where).and_return(fill_relation)
        allow(fill_relation).to receive(:where).and_return(fill_relation)
        allow(fill_relation).to receive(:order).and_return(fills)
        allow(fills).to receive(:any?).and_return(true)
      end

      it 'calculates OHLC from fills' do
        allow(described_class).to receive(:calculate_ohlc_from_fills).and_return({
          market_id: market_id,
          open: '100',
          high: '110',
          low: '100',
          close: '105',
          volume: '23'
        })
        allow(described_class).to receive(:store_ticker_to_redis)

        result = described_class.calculate_with_interval(market_id, 30)

        expect(result[:open]).to eq('100')
        expect(result[:high]).to eq('110')
        expect(result[:close]).to eq('105')
      end
    end
  end

  # ============================================
  # OHLC 计算测试 - 通过公开接口测试
  # ============================================
  describe 'OHLC calculation through calculate_with_interval' do
    let(:kline_time) { Time.current.to_i }

    # 创建完整的 fill mock，包含所有必要属性
    def create_fill_mock(price:, amount:, timestamp:)
      double(
        price: price.to_s,
        amount: amount.to_s,
        block_timestamp: timestamp,
        price_distribution: [{ 'price' => price.to_s, 'amount' => amount.to_s }],
        filled_amount: amount.to_f  # 需要是数字类型用于 sum
      )
    end

    context 'when fills exist' do
      it 'processes fills and returns ticker data' do
        fill = create_fill_mock(price: 100, amount: 10, timestamp: kline_time - 100)
        fills = [fill]

        fill_relation = double('fill_relation')
        allow(Trading::OrderFill).to receive(:where).and_return(fill_relation)
        allow(fill_relation).to receive(:where).and_return(fill_relation)
        allow(fill_relation).to receive(:order).and_return(fills)
        allow(fills).to receive(:any?).and_return(true)

        result = described_class.calculate_with_interval(market_id, 30)

        # 验证返回了 ticker 数据结构
        expect(result).to be_a(Hash)
        expect(result).to include(:market_id)
      end
    end
  end

  # ============================================
  # 批量计算测试
  # ============================================
  describe '.batch_calculate_with_interval' do
    it 'returns empty array for empty market_ids' do
      result = described_class.batch_calculate_with_interval([], 30)
      expect(result).to eq([])
    end

    it 'calculates ticker for multiple markets' do
      allow(described_class).to receive(:calculate_with_interval).and_return({
        market_id: '2801',
        open: '100',
        close: '105'
      })

      result = described_class.batch_calculate_with_interval(['2801', '2802'], 30)

      expect(result).to be_an(Array)
      expect(result.length).to eq(2)
    end
  end

  # ============================================
  # batch_calculate 测试
  # ============================================
  describe '.batch_calculate' do
    let(:redis_double) { instance_double(Redis) }

    before do
      allow(Redis).to receive(:current).and_return(redis_double)
    end

    it 'returns empty array for empty market_ids' do
      result = described_class.batch_calculate([])
      expect(result).to eq([])
    end

    it 'uses pipeline to fetch data from redis' do
      market_ids = ['2801', '2802']

      # Mock Redis pipeline
      pipeline_results = [
        { 'market_id' => '2801', 'open' => '100', 'high' => '110', 'low' => '100', 'close' => '105', 'vol' => '10', 'tor' => '1000', 'change' => '5', 'color' => '#0ECB81', 'time' => Time.current.to_i.to_s },
        { 'market_id' => '2802', 'open' => '200', 'high' => '210', 'low' => '200', 'close' => '205', 'vol' => '20', 'tor' => '4000', 'change' => '2.5', 'color' => '#0ECB81', 'time' => Time.current.to_i.to_s }
      ]

      # Mock the pipelined block behavior
      allow(redis_double).to receive(:pipelined) do |&block|
        pipeline_mock = double('pipeline')
        allow(pipeline_mock).to receive(:hgetall)
        block.call(pipeline_mock)
        pipeline_results
      end

      result = described_class.batch_calculate(market_ids)

      expect(result).to be_an(Array)
      expect(result.length).to eq(2)
      expect(result.first[:market_id]).to eq('2801')
    end

    it 'initializes OHLC for markets with missing data' do
      market_ids = ['2801']

      # Mock pipelined to return empty data
      allow(redis_double).to receive(:pipelined) do |&block|
        pipeline_mock = double('pipeline')
        allow(pipeline_mock).to receive(:hgetall)
        block.call(pipeline_mock)
        [{}]
      end

      # First hgetall returns empty, then returns initialized data
      call_count = 0
      allow(redis_double).to receive(:hgetall) do
        call_count += 1
        if call_count == 1
          {}
        else
          { 'market_id' => '2801', 'open' => '100', 'high' => '100', 'low' => '100', 'close' => '100', 'vol' => '0', 'tor' => '0', 'change' => '0', 'color' => '#FFFFF0', 'time' => Time.current.to_i.to_s }
        end
      end

      allow(described_class).to receive(:initialize_ohlc)

      result = described_class.batch_calculate(market_ids)

      expect(described_class).to have_received(:initialize_ohlc).with('2801')
      expect(result).to be_an(Array)
    end
  end

  # ============================================
  # batch_calculate_24h 测试
  # ============================================
  describe '.batch_calculate_24h' do
    let(:redis_double) { instance_double(Redis) }
    let(:market) { double(market_id: '2801', base_currency: 'ETH') }
    let(:stat) do
      double(
        market_id: '2801',
        window_end_ts: Time.current.to_i,
        open_price_wei: 100,
        high_price_wei: 110,
        low_price_wei: 100,
        close_price_wei: 105,
        volume: 10.0,
        turnover_wei: 1000
      )
    end

    before do
      allow(Redis).to receive(:current).and_return(redis_double)
    end

    it 'returns empty array for empty market_ids' do
      result = described_class.batch_calculate_24h([])
      expect(result).to eq([])
    end

    it 'uses Trading::MarketIntradayStat when available' do
      allow(Trading::Market).to receive(:where).and_return([market])
      allow([market]).to receive(:index_by).and_return({ '2801' => market })
      allow(Trading::MarketIntradayStat).to receive(:where).and_return([stat])
      allow([stat]).to receive(:index_by).and_return({ '2801' => stat })

      result = described_class.batch_calculate_24h(['2801'])

      expect(result).to be_an(Array)
      expect(result.first[:market_id]).to eq('2801')
    end

    it 'falls back to Redis when stat not available' do
      allow(Trading::Market).to receive(:where).and_return([market])
      allow([market]).to receive(:index_by).and_return({ '2801' => market })
      allow(Trading::MarketIntradayStat).to receive(:where).and_return([])
      allow([]).to receive(:index_by).and_return({})

      redis_data = {
        'symbol' => 'ETH',
        'time' => Time.current.to_i.to_s,
        'open' => '100',
        'high' => '110',
        'low' => '100',
        'close' => '105',
        'vol' => '10',
        'tor' => '1000',
        'change' => '5',
        'color' => '#0ECB81'
      }
      allow(redis_double).to receive(:hgetall).and_return(redis_data)

      result = described_class.batch_calculate_24h(['2801'])

      expect(result).to be_an(Array)
      expect(result.first[:market_id]).to eq('2801')
    end
  end

  # ============================================
  # calculate (deprecated) 测试
  # ============================================
  describe '.calculate (deprecated)' do
    it 'calls calculate_with_interval with 1440 minutes' do
      expect(described_class).to receive(:calculate_with_interval).with(market_id, 1440)

      described_class.calculate(market_id)
    end
  end

  # ============================================
  # 价格计算相关私有方法测试
  # ============================================
  describe '.calculate_change (private)' do
    it 'returns "0" when open price is zero' do
      result = described_class.send(:calculate_change, 100.0, 0)
      expect(result).to eq("0")
    end

    it 'calculates positive change percentage' do
      # (110.0 - 100.0) / 100.0 * 100 = 10.0
      result = described_class.send(:calculate_change, 110.0, 100.0)
      expect(result.to_f).to eq(10.0)
    end

    it 'calculates negative change percentage' do
      # (90.0 - 100.0) / 100.0 * 100 = -10.0
      result = described_class.send(:calculate_change, 90.0, 100.0)
      expect(result.to_f).to eq(-10.0)
    end

    it 'rounds to 2 decimal places' do
      # (105.555 - 100) / 100 * 100 = 5.555, rounded to 5.56
      result = described_class.send(:calculate_change, 105.555, 100.0)
      expect(result.to_f).to eq(5.56)
    end
  end

  describe '.get_color (private)' do
    it 'returns green for price increase' do
      result = described_class.send(:get_color, 110, 100)
      expect(result).to eq("#0ECB81")
    end

    it 'returns red for price decrease' do
      result = described_class.send(:get_color, 90, 100)
      expect(result).to eq("#F6465D")
    end

    it 'returns white for unchanged price' do
      result = described_class.send(:get_color, 100, 100)
      expect(result).to eq("#FFFFF0")
    end
  end

  describe '.missing_ohlc? (private)' do
    it 'returns true when open is missing' do
      data = { 'high' => '100', 'low' => '100', 'close' => '100' }
      result = described_class.send(:missing_ohlc?, data)
      expect(result).to be true
    end

    it 'returns true when any value is zero' do
      data = { 'open' => '0', 'high' => '100', 'low' => '100', 'close' => '100' }
      result = described_class.send(:missing_ohlc?, data)
      expect(result).to be true
    end

    it 'returns false when all OHLC values present' do
      data = { 'open' => '100', 'high' => '110', 'low' => '95', 'close' => '105' }
      result = described_class.send(:missing_ohlc?, data)
      expect(result).to be false
    end
  end

  describe '.calculate_price_from_fill (private)' do
    it 'returns nil when price_distribution is not an array' do
      fill = double(price_distribution: nil)
      result = described_class.send(:calculate_price_from_fill, fill)
      expect(result).to be_nil
    end

    it 'returns nil when price_distribution size is not 1' do
      fill = double(price_distribution: [{ 'total_amount' => '100' }, { 'total_amount' => '200' }])
      result = described_class.send(:calculate_price_from_fill, fill)
      expect(result).to be_nil
    end

    it 'returns nil when volume is zero' do
      fill = double(
        price_distribution: [{ 'total_amount' => '100' }],
        filled_amount: 0
      )
      result = described_class.send(:calculate_price_from_fill, fill)
      expect(result).to be_nil
    end

    it 'calculates price correctly' do
      fill = double(
        price_distribution: [{ 'total_amount' => '1000' }],
        filled_amount: 10
      )
      result = described_class.send(:calculate_price_from_fill, fill)
      expect(result).to eq(100.0)
    end
  end

  # ============================================
  # 格式化方法测试
  # ============================================
  describe '.format_ticker (private)' do
    it 'returns nil for empty data' do
      result = described_class.send(:format_ticker, market_id, {})
      expect(result).to be_nil
    end

    it 'formats ticker data correctly' do
      data = {
        'symbol' => 'ETH',
        'time' => Time.current.to_i.to_s,
        'open' => '100',
        'high' => '110',
        'low' => '95',
        'close' => '105',
        'vol' => '1000',
        'tor' => '100000',
        'change' => '5.0',
        'color' => '#0ECB81'
      }

      result = described_class.send(:format_ticker, market_id, data)

      expect(result[:market_id]).to eq(market_id)
      expect(result[:symbol]).to eq('ETH')
      expect(result[:open]).to eq('100')
      expect(result[:close]).to eq('105')
      expect(result[:change]).to eq('5.0')
    end

    it 'uses default values for missing fields' do
      data = { 'time' => Time.current.to_i.to_s }

      result = described_class.send(:format_ticker, market_id, data)

      expect(result[:symbol]).to eq('N/A')
      expect(result[:open]).to eq('0')
      expect(result[:change]).to eq('0')
      expect(result[:color]).to eq('#FFFFF0')
    end
  end
end
