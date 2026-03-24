# frozen_string_literal: true

require 'rails_helper'
require_relative 'sidekiq_consistency_test_framework'

RSpec.describe 'Broadcast Consistency' do
  include SidekiqConsistencyTestFramework
  
  let(:tester) { SidekiqConsistencyTestFramework::ConsistencyTester.new }
  let(:market_id) { 'ETH-USD' }
  
  before do
    # Mock外部依赖
    allow(Realtime::MarketBroadcastService).to receive(:broadcast_ticker).and_return(true)
    allow(Realtime::MarketBroadcastService).to receive(:broadcast_kline).and_return(true)
    allow(Realtime::MarketBroadcastService).to receive(:broadcast_trade).and_return(true)
    allow(Realtime::MarketBroadcastService).to receive(:broadcast_depth).and_return(true)
    
    # Mock Redis订阅检查
    allow(Redis.current).to receive(:get).with(/sub_count:/).and_return("1")
    
    # Mock数据服务
    allow(RuntimeCache::MarketDataStore).to receive(:get_trades).and_return([])
    allow(MarketData::KlineBuilder).to receive(:build).and_return([])
    allow(MarketData::KlineBuilder).to receive(:build_realtime).and_return([])
  end
  
  describe 'UnifiedBroadcastWorker vs Legacy Broadcast Jobs' do
    context 'Ticker broadcasting' do
      it 'produces consistent ticker broadcast behavior' do
        test_data = [
          ["#{market_id}@TICKER_1", Time.current.to_i],
          ["BTC-USD@TICKER_5", Time.current.to_i]
        ]
        
        tester.compare_behaviors("Ticker batch broadcasting") do
          # 模拟原有TickerBatchWorker的逻辑
          legacy_result = simulate_legacy_ticker_batch(test_data)
          
          # 执行重构后的UnifiedBroadcastWorker
          refactored_result = UnifiedBroadcastWorker.new.perform('ticker_batch', { batch: test_data })
          
          [normalize_broadcast_result(legacy_result), normalize_broadcast_result(refactored_result)]
        end
        
        tester.print_summary
        expect(tester.results[:failed]).to be_empty
      end
    end
    
    context 'Kline broadcasting' do
      it 'produces consistent kline broadcast behavior' do
        test_data = [
          ["#{market_id}@KLINE_60", Time.current.to_i],
          ["BTC-USD@KLINE_300", Time.current.to_i]
        ]
        
        tester.compare_behaviors("Kline batch broadcasting") do
          # 模拟原有KlineBatchWorker的逻辑
          legacy_result = simulate_legacy_kline_batch(test_data)
          
          # 执行重构后的UnifiedBroadcastWorker
          refactored_result = UnifiedBroadcastWorker.new.perform('kline_batch', { 
            batch: test_data,
            is_realtime: false
          })
          
          [normalize_broadcast_result(legacy_result), normalize_broadcast_result(refactored_result)]
        end
        
        tester.print_summary
        expect(tester.results[:failed]).to be_empty
      end
    end
    
    context 'Trade broadcasting' do
      it 'produces consistent trade broadcast behavior' do
        test_data = [
          ["#{market_id}@TRADE", Time.current.to_i]
        ]
        
        tester.compare_behaviors("Trade batch broadcasting") do
          # 模拟原有TradeBatchWorker的逻辑
          legacy_result = simulate_legacy_trade_batch(test_data)
          
          # 执行重构后的UnifiedBroadcastWorker
          refactored_result = UnifiedBroadcastWorker.new.perform('trade_batch', { batch: test_data })
          
          [normalize_broadcast_result(legacy_result), normalize_broadcast_result(refactored_result)]
        end
        
        tester.print_summary
        expect(tester.results[:failed]).to be_empty
      end
    end
    
    context 'Depth broadcasting' do
      it 'produces consistent depth broadcast behavior' do
        tester.compare_behaviors("Depth broadcasting") do
          params = { market_id: market_id, limit: 20 }
          
          # 模拟原有DepthBroadcastJob的逻辑
          legacy_result = simulate_legacy_depth_broadcast(params)
          
          # 执行重构后的UnifiedBroadcastWorker
          refactored_result = UnifiedBroadcastWorker.new.perform('depth', params)
          
          [normalize_broadcast_result(legacy_result), normalize_broadcast_result(refactored_result)]
        end
        
        tester.print_summary
        expect(tester.results[:failed]).to be_empty
      end
    end
  end
  
  describe 'Broadcast Content Verification' do
    it 'verifies broadcast calls are made with correct parameters' do
      tester.compare_behaviors("Broadcast parameter consistency") do
        test_batch = [["#{market_id}@TICKER_1", Time.current.to_i]]
        
        # 记录广播调用
        broadcast_calls_legacy = []
        broadcast_calls_refactored = []
        
        # Mock并记录调用
        allow(Realtime::MarketBroadcastService).to receive(:broadcast_ticker) do |market_id|
          broadcast_calls_legacy << { method: :broadcast_ticker, market_id: market_id }
          true
        end
        
        # 执行原有逻辑
        simulate_legacy_ticker_batch(test_batch)
        
        # 重置记录
        allow(Realtime::MarketBroadcastService).to receive(:broadcast_ticker) do |market_id|
          broadcast_calls_refactored << { method: :broadcast_ticker, market_id: market_id }
          true
        end
        
        # 执行重构后逻辑
        UnifiedBroadcastWorker.new.perform('ticker_batch', { batch: test_batch })
        
        [broadcast_calls_legacy, broadcast_calls_refactored]
      end
      
      tester.print_summary
      expect(tester.results[:failed]).to be_empty
    end
  end
  
  private
  
  # 模拟原有的广播逻辑
  def simulate_legacy_ticker_batch(batch)
    success_count = 0
    failed_count = 0
    
    batch.each do |pair|
      topic, _ = pair
      parsed = Realtime::TopicParser.parse_topic(topic)
      next unless parsed
      
      market_id = parsed[:market_id]
      
      if Realtime::MarketBroadcastService.broadcast_ticker(market_id)
        success_count += 1
      else
        failed_count += 1
      end
    end
    
    {
      success: true,
      stats: {
        type: 'ticker_batch',
        success: success_count,
        failed: failed_count,
        total: success_count + failed_count
      }
    }
  end
  
  def simulate_legacy_kline_batch(batch)
    success_count = 0
    failed_count = 0
    
    batch.each do |pair|
      topic, aligned_ts = pair
      parsed = Realtime::TopicParser.parse_topic(topic)
      next unless parsed
      
      market_id = parsed[:market_id]
      interval = parsed[:interval]
      
      # 获取K线数据
      start_time = aligned_ts - (interval * 60)
      kline_data = MarketData::KlineBuilder.build(market_id, interval, start_time, aligned_ts)
      
      if Realtime::MarketBroadcastService.broadcast_kline(market_id, interval, kline_data)
        success_count += 1
      else
        failed_count += 1
      end
    end
    
    {
      success: true,
      stats: {
        type: 'kline_batch',
        success: success_count,
        failed: failed_count,
        total: success_count + failed_count
      }
    }
  end
  
  def simulate_legacy_trade_batch(batch)
    success_count = 0
    failed_count = 0
    
    batch.each do |pair|
      topic, _ = pair
      parsed = Realtime::TopicParser.parse_topic(topic)
      next unless parsed
      
      market_id = parsed[:market_id]
      trades = RuntimeCache::MarketDataStore.get_trades(market_id)
      
      if trades && Realtime::MarketBroadcastService.broadcast_trade(market_id, trades)
        success_count += 1
      else
        failed_count += 1
      end
    end
    
    {
      success: true,
      stats: {
        type: 'trade_batch',
        success: success_count,
        failed: failed_count,
        total: success_count + failed_count
      }
    }
  end
  
  def simulate_legacy_depth_broadcast(params)
    market_id = params[:market_id]
    limit = params[:limit] || 20
    
    success = Realtime::MarketBroadcastService.broadcast_depth(market_id, limit)
    
    {
      success: success,
      stats: {
        type: 'depth',
        success: success ? 1 : 0,
        failed: success ? 0 : 1,
        total: 1
      }
    }
  end
  
  def normalize_broadcast_result(result)
    # 标准化结果格式，忽略时间戳等无关差异
    return {} unless result.is_a?(Hash)
    
    {
      success: result[:success],
      stats: result[:stats]&.slice(:type, :success, :failed, :total)
    }
  end
end
