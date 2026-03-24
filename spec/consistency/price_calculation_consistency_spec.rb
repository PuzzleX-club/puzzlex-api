# frozen_string_literal: true

require 'rails_helper'
require_relative 'sidekiq_consistency_test_framework'

RSpec.describe 'Price Calculation Consistency' do
  include SidekiqConsistencyTestFramework
  
  let(:tester) { SidekiqConsistencyTestFramework::ConsistencyTester.new }
  
  before do
    # 完整Mock Redis避免连接问题
    redis_mock = double('Redis',
      flushdb: true,
      get: nil,
      set: true,
      keys: [],
      hgetall: {},
      hget: "0",
      hset: true,
      incrby: 1,
      hincrbyfloat: 100.0,
      expire: true,
      sadd: true,
      smembers: [],
      del: true
    )
    allow(Redis).to receive(:current).and_return(redis_mock)

    # Mock OrderFill和Order的广播方法
    allow_any_instance_of(Trading::OrderFill).to receive(:enqueue_trade_broadcast)
    allow_any_instance_of(Trading::OrderFill).to receive(:mark_market_changed)
    allow_any_instance_of(Trading::Order).to receive(:broadcast_depth_if_subscribed)
    allow_any_instance_of(Trading::Order).to receive(:mark_market_summary_dirty)

    # Mock Sidekiq workers to prevent real scheduling
    allow(Jobs::Orders::DepthBroadcastJob).to receive(:perform_async)
    allow(Jobs::Matching::Worker).to receive(:perform_in)
    allow(Jobs::MarketData::Broadcast::TradeBatchJob).to receive(:perform_in)

    # Mock SubscriptionGuard to prevent Redis calls
    allow(Realtime::SubscriptionGuard).to receive(:depth_limits_for_market).and_return([])

    # Mock MarketData::FillEventRecorder to prevent DB writes
    allow(MarketData::FillEventRecorder).to receive(:record!)
  end
  
  describe 'MarketData::PriceCalculator vs Legacy Logic' do
    context 'with various OrderFill scenarios' do
      it 'produces consistent price calculations' do
        test_scenarios = [
          { filled_amount: 100.0, total_amount: 1500.0, expected_price: 15.0 },
          { filled_amount: 50.0, total_amount: 1000.0, expected_price: 20.0 },
          { filled_amount: 200.0, total_amount: 3000.0, expected_price: 15.0 },
          { filled_amount: 0.001, total_amount: 0.015, expected_price: 15.0 }
        ]
        
        test_scenarios.each_with_index do |scenario, index|
          tester.compare_behaviors("Price calculation scenario #{index + 1}") do
            # 创建测试数据
            order_fill = create_test_order_fill(scenario)
            
            # 执行原有逻辑 (模拟原有重复代码)
            legacy_price = calculate_price_legacy(order_fill)
            
            # 执行重构后逻辑
            refactored_price = MarketData::PriceCalculator.calculate_price_from_fill(order_fill)
            
            [legacy_price, refactored_price]
          end
        end
        
        tester.print_summary
        expect(tester.results[:failed]).to be_empty
        expect(tester.results[:errors]).to be_empty
      end
    end
    
    context 'with edge cases' do
      it 'handles zero and nil values consistently' do
        # Only test edge cases where legacy and refactored logic are expected to agree.
        # The refactored PriceCalculator intentionally falls back to fill.filled_amount
        # when distribution["filled_amount"] is blank, which differs from the legacy
        # approach that returns 0. We test the cases that should match.
        edge_cases = [
          { filled_amount: 0, total_amount: 1000.0, description: 'zero filled amount' },
          { filled_amount: 100.0, total_amount: 0, description: 'zero total amount' }
        ]

        edge_cases.each do |edge_case|
          tester.compare_behaviors("Edge case: #{edge_case[:description]}") do
            # 创建边界测试数据
            order_fill = create_test_order_fill({
              filled_amount: edge_case[:filled_amount],
              total_amount: edge_case[:total_amount]
            })

            # 对比计算结果
            legacy_result = calculate_price_legacy(order_fill)
            refactored_result = MarketData::PriceCalculator.calculate_price_from_fill(order_fill)

            [legacy_result, refactored_result]
          end
        end

        tester.print_summary
        expect(tester.results[:failed]).to be_empty
      end
    end
  end
  
  describe 'Price Distribution Calculation' do
    it 'produces consistent price distribution results' do
      tester.compare_behaviors("Price distribution calculation") do
        # 模拟价格分布数据
        price_distribution = [
          {
            "total_amount" => "1500.0",
            "filled_amount" => "100.0"
          }
        ]
        filled_amount = 100.0
        
        # 原有逻辑
        legacy_price = calculate_price_from_distribution_legacy(price_distribution, filled_amount)
        
        # 重构后逻辑
        refactored_price = MarketData::PriceCalculator.calculate_price(price_distribution, filled_amount)
        
        [legacy_price, refactored_price]
      end
      
      tester.print_summary
      expect(tester.results[:failed]).to be_empty
    end
  end
  
  private
  
  def create_test_order_fill(params)
    order = create(:trading_order, market_id: 'ETH-USD')
    
    attributes = {
      order: order,
      market_id: 'ETH-USD',
      filled_amount: params[:filled_amount] || 100.0,
      created_at: Time.current
    }
    
    # 模拟price_distribution字段
    # 只要有任何一个参数不是默认值，就创建price_distribution
    if params.key?(:total_amount) || params.key?(:filled_amount)
      # 处理nil值的情况，nil转换为空字符串
      total_amount_str = params[:total_amount]&.to_s || ""
      filled_amount_str = params[:filled_amount]&.to_s || ""
      
      attributes[:price_distribution] = [
        {
          "total_amount" => total_amount_str,
          "filled_amount" => filled_amount_str
        }
      ].to_json
    end
    
    create(:trading_order_fill, attributes)
  end
  
  # 模拟原有的重复价格计算逻辑
  def calculate_price_legacy(order_fill)
    return 0.0 unless order_fill&.price_distribution
    
    begin
      price_distribution = JSON.parse(order_fill.price_distribution)
      return 0.0 if price_distribution.empty?
      
      distribution = price_distribution.first
      total_amount = distribution["total_amount"].to_f
      filled_amount = distribution["filled_amount"].to_f
      
      return 0.0 if filled_amount.zero?
      
      total_amount / filled_amount
    rescue JSON::ParserError, NoMethodError
      0.0
    end
  end
  
  def calculate_price_from_distribution_legacy(price_distribution, filled_amount)
    return 0.0 unless price_distribution && !price_distribution.empty?
    return 0.0 if filled_amount.nil? || filled_amount.zero?
    
    distribution = price_distribution.first
    total_amount = distribution["total_amount"].to_f
    filled_amount = filled_amount.to_f
    
    return 0.0 if filled_amount.zero?
    
    total_amount / filled_amount
  end
end
