# frozen_string_literal: true

require 'rails_helper'
require_relative 'sidekiq_consistency_test_framework'

RSpec.describe 'Broadcast Edge Cases Consistency' do
  include SidekiqConsistencyTestFramework
  
  let(:tester) { SidekiqConsistencyTestFramework::ConsistencyTester.new }
  let(:market_id) { 'ETH-USD' }
  
  before do
    # Mock依赖
    allow(Realtime::MarketBroadcastService).to receive(:broadcast_ticker).and_return(true)
    allow(Realtime::MarketBroadcastService).to receive(:broadcast_kline).and_return(true)
    allow(Realtime::MarketBroadcastService).to receive(:broadcast_trade).and_return(true)
    allow(Realtime::MarketBroadcastService).to receive(:batch_broadcast_tickers).and_return({ success: [], failed: [] })
    allow(Realtime::MarketBroadcastService).to receive(:broadcast_market_realtime).and_return(true)
    allow(Redis.current).to receive(:get).with(/sub_count:/).and_return("1")
    allow(RuntimeCache::MarketDataStore).to receive(:get_trades).and_return([])
    allow(MarketData::KlineBuilder).to receive(:build).and_return([])
    allow(MarketData::KlineBuilder).to receive(:build_realtime).and_return([])
  end
  
  describe 'Edge cases and error handling' do
    context 'Empty batch handling' do
      it 'handles empty batches consistently' do
        tester.compare_behaviors("Empty ticker batch") do
          # 空批次
          empty_batch = []
          
          # Legacy逻辑
          legacy_result = simulate_legacy_ticker_batch(empty_batch)
          
          # 重构逻辑
          refactored_result = UnifiedBroadcastWorker.new.perform('ticker_batch', { batch: empty_batch })
          
          [normalize_result(legacy_result), normalize_result(refactored_result)]
        end
        
        tester.print_summary
        expect(tester.results[:failed]).to be_empty
      end
    end
    
    context 'Invalid topic handling' do
      it 'handles invalid topics consistently' do
        tester.compare_behaviors("Invalid topic format") do
          # 无效的topic格式
          invalid_batch = [
            ["INVALID_TOPIC", Time.current.to_i],
            ["", Time.current.to_i],
            [nil, Time.current.to_i]
          ]
          
          # Legacy逻辑
          legacy_result = simulate_legacy_ticker_batch(invalid_batch)
          
          # 重构逻辑  
          refactored_result = UnifiedBroadcastWorker.new.perform('ticker_batch', { batch: invalid_batch })
          
          [normalize_result(legacy_result), normalize_result(refactored_result)]
        end
        
        tester.print_summary
        expect(tester.results[:failed]).to be_empty
      end
    end
    
    context 'Mixed success/failure scenarios' do
      it 'handles partial failures consistently' do
        # Mock部分失败
        call_count = 0
        allow(Realtime::MarketBroadcastService).to receive(:broadcast_ticker) do |market_id|
          call_count += 1
          call_count.odd? # 第1,3,5...次调用成功，第2,4,6...次失败
        end
        
        tester.compare_behaviors("Mixed success/failure") do
          mixed_batch = [
            ["ETH-USD@TICKER_1", Time.current.to_i],
            ["BTC-USD@TICKER_1", Time.current.to_i],
            ["USDT-USD@TICKER_1", Time.current.to_i]
          ]
          
          # 重置计数器
          call_count = 0
          legacy_result = simulate_legacy_ticker_batch(mixed_batch)
          
          call_count = 0
          refactored_result = UnifiedBroadcastWorker.new.perform('ticker_batch', { batch: mixed_batch })
          
          [normalize_result(legacy_result), normalize_result(refactored_result)]
        end
        
        tester.print_summary
        expect(tester.results[:failed]).to be_empty
      end
    end
    
    context 'Real-time kline broadcasting' do
      it 'handles realtime flag consistently' do
        tester.compare_behaviors("Realtime kline broadcasting") do
          kline_batch = [
            ["ETH-USD@KLINE_60", Time.current.to_i]
          ]
          
          # Legacy实时K线逻辑
          legacy_result = simulate_legacy_kline_batch(kline_batch, is_realtime: true)
          
          # 重构实时K线逻辑
          refactored_result = UnifiedBroadcastWorker.new.perform('kline_batch', { 
            batch: kline_batch,
            is_realtime: true
          })
          
          [normalize_result(legacy_result), normalize_result(refactored_result)]
        end
        
        tester.print_summary
        expect(tester.results[:failed]).to be_empty
      end
    end
    
    context 'Market realtime broadcasting' do
      it 'handles market realtime consistently' do
        tester.compare_behaviors("Market realtime broadcasting") do
          params = { topic: 'MARKET@realtime' }
          
          # Legacy逻辑
          legacy_result = simulate_legacy_market_realtime(params)
          
          # 重构逻辑
          refactored_result = UnifiedBroadcastWorker.new.perform('market_realtime', params)
          
          [normalize_result(legacy_result), normalize_result(refactored_result)]
        end
        
        tester.print_summary
        expect(tester.results[:failed]).to be_empty
      end
    end
    
    context 'Ticker realtime with multiple markets' do
      it 'handles batch ticker realtime consistently' do
        tester.compare_behaviors("Ticker realtime batch") do
          market_ids = ['ETH-USD', 'BTC-USD', 'USDT-USD']
          
          # Legacy逻辑
          legacy_result = simulate_legacy_ticker_realtime(market_ids)
          
          # 重构逻辑
          refactored_result = UnifiedBroadcastWorker.new.perform('ticker_realtime', { 
            market_ids: market_ids 
          })
          
          [normalize_result(legacy_result), normalize_result(refactored_result)]
        end
        
        tester.print_summary
        expect(tester.results[:failed]).to be_empty
      end
    end
  end
  
  private
  
  # 模拟Legacy广播逻辑
  def simulate_legacy_ticker_batch(batch, is_realtime: false)
    success_count = 0
    failed_count = 0
    
    batch.each do |pair|
      topic, _ = pair
      next unless topic
      
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
  
  def simulate_legacy_kline_batch(batch, is_realtime: false)
    success_count = 0
    failed_count = 0
    
    batch.each do |pair|
      topic, aligned_ts = pair
      parsed = Realtime::TopicParser.parse_topic(topic)
      next unless parsed
      
      market_id = parsed[:market_id]
      interval = parsed[:interval]
      
      if is_realtime
        kline_data = MarketData::KlineBuilder.build_realtime(market_id, interval)
      else
        start_time = aligned_ts - (interval * 60)
        kline_data = MarketData::KlineBuilder.build(market_id, interval, start_time, aligned_ts)
      end
      
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
  
  def simulate_legacy_market_realtime(params)
    topic = params[:topic] || 'MARKET@realtime'
    success = Realtime::MarketBroadcastService.broadcast_market_realtime(topic)
    
    {
      success: success,
      stats: {
        type: 'market_realtime',
        success: success ? 1 : 0,
        failed: success ? 0 : 1,
        total: 1
      }
    }
  end
  
  def simulate_legacy_ticker_realtime(market_ids)
    result = Realtime::MarketBroadcastService.batch_broadcast_tickers(market_ids)
    
    {
      success: result[:failed].empty?,
      stats: {
        type: 'ticker_realtime',
        success: result[:success].size,
        failed: result[:failed].size,
        total: result[:success].size + result[:failed].size
      }
    }
  end
  
  def normalize_result(result)
    return {} unless result.is_a?(Hash)
    
    {
      success: result[:success],
      stats: result[:stats]&.slice(:type, :success, :failed, :total)
    }
  end
end
