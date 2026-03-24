# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Realtime::MarketBroadcastService do
  include ServiceTestHelpers

  let(:market_id) { 101 }
  let(:redis) { stub_redis }

  before do
    stub_action_cable
  end

  describe '.broadcast_ticker' do
    let(:ticker_data) do
      {
        'symbol' => 'NFT/ETH',
        'intvl' => '60',
        'time' => Time.current.to_i.to_s,
        'open' => '100',
        'high' => '110',
        'low' => '95',
        'close' => '105',
        'vol' => '1000',
        'tor' => '105000',
        'change' => '+5%',
        'color' => 'green'
      }
    end

    before do
      allow(redis).to receive(:hgetall).with("market:#{market_id}").and_return(ticker_data)
      allow(redis).to receive(:scard).and_return(1)
      allow(redis).to receive(:get).and_return('1')
    end

    it 'broadcasts ticker data to correct channel' do
      expect(ActionCable.server).to receive(:broadcast).with(
        "#{market_id}@TICKER",
        hash_including(:data)
      )

      described_class.broadcast_ticker(market_id)
    end

    it 'returns false when no ticker data' do
      allow(redis).to receive(:hgetall).and_return({})

      result = described_class.broadcast_ticker(market_id)

      expect(result).to be false
    end

    it 'formats ticker data as array' do
      expect(ActionCable.server).to receive(:broadcast) do |channel, data|
        expect(channel).to eq("#{market_id}@TICKER")
        expect(data[:data]).to be_an(Array)
        expect(data[:data][0]).to eq(market_id)
      end

      described_class.broadcast_ticker(market_id)
    end
  end

  describe '.batch_broadcast_tickers' do
    let(:market_ids) { [101, 102, 103] }

    before do
      allow(redis).to receive(:hgetall).and_return({
        'symbol' => 'NFT/ETH',
        'intvl' => '60',
        'time' => Time.current.to_i.to_s,
        'open' => '100',
        'high' => '100',
        'low' => '100',
        'close' => '100',
        'vol' => '0',
        'tor' => '0',
        'change' => '0%',
        'color' => 'gray'
      })
      allow(redis).to receive(:scard).and_return(1)
      allow(redis).to receive(:get).and_return('1')
    end

    it 'broadcasts to all markets' do
      expect(ActionCable.server).to receive(:broadcast).exactly(3).times

      described_class.batch_broadcast_tickers(market_ids)
    end
  end

  describe '.broadcast_kline' do
    let(:interval) { 60 }
    let(:kline_data) { [Time.current.to_i, 100, 110, 95, 105, '1000', '105000'] }

    before do
      allow(MarketData::KlineBuilder).to receive(:build).and_return(kline_data)
      allow(redis).to receive(:scard).and_return(1)
      allow(redis).to receive(:get).and_return('1')
      allow(redis).to receive(:setex).and_return(true)
    end

    it 'broadcasts kline data to correct channel' do
      expect(ActionCable.server).to receive(:broadcast).with(
        "#{market_id}@KLINE_#{interval}",
        hash_including(:topic, :data)
      )

      described_class.broadcast_kline(market_id, interval)
    end

    it 'uses provided kline_data if given' do
      custom_data = [Time.current.to_i, 200, 220, 190, 210, '2000', '420000']

      expect(ActionCable.server).to receive(:broadcast) do |_channel, message|
        expect(message[:data]).to eq(custom_data)
      end

      described_class.broadcast_kline(market_id, interval, custom_data)
    end

    it 'records broadcast time for non-zero volume klines' do
      expect(redis).to receive(:setex).with(/kline_last_broadcast/, 15, anything)

      described_class.broadcast_kline(market_id, interval, kline_data)
    end

    it 'does not record broadcast time for zero volume klines' do
      zero_volume_kline = [Time.current.to_i, 100, 100, 100, 100, '0', '0']

      expect(redis).not_to receive(:setex).with(/kline_last_broadcast/, anything, anything)

      described_class.broadcast_kline(market_id, interval, zero_volume_kline)
    end
  end

  describe '.broadcast_depth' do
    let(:limit) { 20 }
    let(:depth_data) do
      {
        market_id: market_id,
        levels: limit,
        bids: [['100', '10', '0xbid1']],
        asks: [['110', '5', '0xask1']]
      }
    end

    before do
      depth_service = instance_double(MarketData::OrderBookDepth)
      allow(MarketData::OrderBookDepth).to receive(:new).and_return(depth_service)
      allow(depth_service).to receive(:call).and_return(depth_data)
      allow(redis).to receive(:scard).and_return(1)
      allow(redis).to receive(:get).and_return('1')
      allow(redis).to receive(:setex).and_return(true)
    end

    it 'broadcasts depth data to correct channel' do
      expect(ActionCable.server).to receive(:broadcast).with(
        "#{market_id}@DEPTH_#{limit}",
        hash_including(:topic, :data)
      )

      described_class.broadcast_depth(market_id, limit)
    end

    it 'adds server_time to depth data' do
      expect(ActionCable.server).to receive(:broadcast) do |_channel, message|
        expect(message[:data][:server_time]).to be_present
      end

      described_class.broadcast_depth(market_id, limit)
    end

    it 'marks heartbeat broadcasts' do
      expect(ActionCable.server).to receive(:broadcast) do |_channel, message|
        expect(message[:data][:is_heartbeat]).to be true
      end

      described_class.broadcast_depth(market_id, limit, true)
    end

    it 'records last update time for non-heartbeat broadcasts' do
      expect(redis).to receive(:setex).with("depth_last_update:#{market_id}", 30, anything)

      described_class.broadcast_depth(market_id, limit, false)
    end
  end

  describe '.broadcast_trade' do
    let(:trade_data) do
      {
        price: '105',
        amount: '10',
        side: 'buy',
        timestamp: Time.current.to_i
      }
    end

    before do
      allow(redis).to receive(:scard).and_return(1)
      allow(redis).to receive(:get).and_return('1')
    end

    it 'broadcasts trade data to correct channel' do
      expect(ActionCable.server).to receive(:broadcast).with(
        "#{market_id}@TRADE",
        hash_including(:topic, :data)
      )

      described_class.broadcast_trade(market_id, trade_data)
    end
  end

  describe '.broadcast_market_realtime' do
    let(:markets) do
      [
        { market_id: 101, base_currency: 'ETH' },
        { market_id: 102, base_currency: 'ETH' }
      ]
    end

    before do
      allow(Trading::Market).to receive(:select).and_return(double(map: markets))
      allow(redis).to receive(:hgetall).and_return({
        'close' => '100',
        'vol' => '1000',
        'change' => '+5%',
        'high' => '110',
        'low' => '95',
        'tor' => '100000'
      })
      allow(redis).to receive(:scard).and_return(1)
      allow(redis).to receive(:get).and_return('1')
    end

    it 'broadcasts to MARKET@realtime topic by default' do
      expect(ActionCable.server).to receive(:broadcast).with(
        'MARKET@realtime',
        hash_including(:topic, :data)
      )

      described_class.broadcast_market_realtime
    end

    it 'allows custom topic' do
      custom_topic = 'MARKET@custom'

      expect(ActionCable.server).to receive(:broadcast).with(
        custom_topic,
        hash_including(:topic)
      )

      described_class.broadcast_market_realtime(custom_topic)
    end
  end

end
