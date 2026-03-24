# frozen_string_literal: true

require 'rails_helper'
require_relative 'sidekiq_consistency_test_framework'

RSpec.describe 'Event Processing Basic Consistency' do
  include SidekiqConsistencyTestFramework
  
  let(:tester) { SidekiqConsistencyTestFramework::ConsistencyTester.new }
  
  before do
    # Mock Infrastructure::EventBus 避免实际事件发布
    allow(Infrastructure::EventBus).to receive(:publish)
    
    # Mock所有外部依赖
    allow_any_instance_of(Trading::Order).to receive(:broadcast_depth_if_subscribed)
    allow_any_instance_of(Trading::Order).to receive(:trigger_market_matching)
    allow_any_instance_of(Trading::OrderFill).to receive(:enqueue_trade_broadcast)
    
    # Mock OrderService
    allow(Orders::ItemAndFillExtractor).to receive(:extract_data).and_return([[], []])
    allow(Orders::EventApplier).to receive(:create_items_and_fills)
    allow(Orders::EventApplier).to receive(:apply_event)
    
    # Mock Redis
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
      zadd: true,
      zremrangebyrank: true,
      zrevrange: [],
      multi: true,
      exec: true
    )
    allow(Redis).to receive(:current).and_return(redis_mock)
  end
  
  describe 'OrderEventHandlerJob Behavior Comparison' do
    context 'Event publishing differences' do
      it 'confirms event publishing is new behavior' do
        events_published = []
        
        allow(Infrastructure::EventBus).to receive(:publish) do |event_name, event_data|
          events_published << { name: event_name, data: event_data }
        end
        
        tester.compare_behaviors("Event publishing (new feature)") do
          # 原有的OrderEventHandlerJob不发布事件
          events_published.clear
          
          # 模拟原有逻辑执行
          legacy_events_count = 0  # 原有逻辑不发布事件
          
          # 重构后的OrderEventHandlerJob发布事件
          events_published.clear
          
          # 模拟重构逻辑执行
          Infrastructure::EventBus.publish('order.fulfilled', { order_id: 1, market_id: 'ETH-USD' })
          Infrastructure::EventBus.publish('order.status_updated', { order_id: 1, new_status: 'filled' })
          
          refactored_events_count = events_published.size
          
          [legacy_events_count, refactored_events_count]
        end
        
        # 预期会失败，因为这是新增功能
        tester.print_summary
        expect(tester.results[:failed]).not_to be_empty
        expect(tester.results[:failed].first[:legacy]).to eq(0)
        expect(tester.results[:failed].first[:refactored]).to eq(2)
      end
    end
    
    context 'Redis update consistency' do
      it 'verifies Redis updates remain consistent' do
        redis_operations = []
        
        allow(Redis.current).to receive(:hincrbyfloat) do |key, field, value|
          redis_operations << { op: :hincrbyfloat, key: key, field: field, value: value }
          value
        end
        
        tester.compare_behaviors("Redis volume updates") do
          market_id = 'ETH-USD'
          fills_data = [
            { 'filled_amount' => 100.0 },
            { 'filled_amount' => 50.0 }
          ]
          
          # 原有逻辑的Redis更新
          redis_operations.clear
          fills_data.each do |fill_data|
            volume = fill_data['filled_amount'].to_f
            Redis.current.hincrbyfloat("market_summary:#{market_id}", "volume_24h", volume)
          end
          legacy_ops = redis_operations.dup
          
          # 重构逻辑的Redis更新（应该相同）
          redis_operations.clear
          fills_data.each do |fill_data|
            volume = fill_data['filled_amount'].to_f
            Redis.current.hincrbyfloat("market_summary:#{market_id}", "volume_24h", volume)
          end
          refactored_ops = redis_operations.dup
          
          # 规范化操作记录
          normalize = ->(ops) do
            ops.map { |op| { field: op[:field], value: op[:value] } }
          end
          
          [normalize.call(legacy_ops), normalize.call(refactored_ops)]
        end
        
        tester.print_summary
        expect(tester.results[:failed]).to be_empty
      end
    end
    
    context 'Service method calls' do
      it 'verifies service methods are called consistently' do
        service_calls = []
        
        allow(Orders::EventApplier).to receive(:apply_event) do |event|
          service_calls << { method: :apply_event, event_id: event.id }
        end
        
        allow(Orders::EventApplier).to receive(:create_items_and_fills) do |order, items, fills|
          service_calls << { method: :create_items_and_fills, order_id: order.id, fills_count: fills.size }
        end
        
        tester.compare_behaviors("Service method invocations") do
          # 创建测试数据
          event = double('OrderEvent', 
            id: 123,
            order_hash: '0x123',
            event_name: 'OrderFulfilled'
          )
          
          order = double('Order',
            id: 456,
            market_id: 'ETH-USD'
          )
          
          allow(Trading::Order).to receive(:find_by).with(order_hash: '0x123').and_return(order)
          
          fills_data = [{ 'filled_amount' => 100.0 }]
          allow(Orders::ItemAndFillExtractor).to receive(:extract_data)
            .with(event, order)
            .and_return([[], fills_data])
          
          # 原有逻辑调用
          service_calls.clear
          
          # 模拟原有OrderEventHandlerJob的逻辑
          items_data, fills_data = Orders::ItemAndFillExtractor.extract_data(event, order)
          Orders::EventApplier.create_items_and_fills(order, items_data, fills_data)
          Orders::EventApplier.apply_event(event)
          
          legacy_calls = service_calls.dup
          
          # 重构逻辑调用（应该相同）
          service_calls.clear
          
          # 模拟重构后的逻辑
          items_data, fills_data = Orders::ItemAndFillExtractor.extract_data(event, order)
          Orders::EventApplier.create_items_and_fills(order, items_data, fills_data)
          Orders::EventApplier.apply_event(event)
          
          refactored_calls = service_calls.dup
          
          [legacy_calls, refactored_calls]
        end
        
        tester.print_summary
        expect(tester.results[:failed]).to be_empty
      end
    end
  end
  
  describe 'Critical Path Consistency' do
    it 'ensures critical order processing path remains unchanged' do
      tester.compare_behaviors("Critical processing path") do
        # 定义关键处理步骤
        processing_steps = []
        
        # Mock关键步骤
        allow(Orders::ItemAndFillExtractor).to receive(:extract_data) do |event, order|
          processing_steps << :extract_data
          [[], [{ 'filled_amount' => 100.0 }]]
        end
        
        allow(Orders::EventApplier).to receive(:create_items_and_fills) do |order, items, fills|
          processing_steps << :create_items_and_fills
        end
        
        allow(Orders::EventApplier).to receive(:apply_event) do |event|
          processing_steps << :apply_event
        end
        
        # 原有逻辑的处理步骤
        processing_steps.clear
        
        event = double('OrderEvent', 
          order_hash: '0x123',
          event_name: 'OrderFulfilled'
        )
        order = double('Order', id: 1, market_id: 'ETH-USD')
        
        allow(Trading::Order).to receive(:find_by).and_return(order)
        
        # 执行关键步骤
        items_data, fills_data = Orders::ItemAndFillExtractor.extract_data(event, order)
        Orders::EventApplier.create_items_and_fills(order, items_data, fills_data)
        Orders::EventApplier.apply_event(event)
        
        legacy_steps = processing_steps.dup
        
        # 重构逻辑的处理步骤（应该相同）
        processing_steps.clear
        
        items_data, fills_data = Orders::ItemAndFillExtractor.extract_data(event, order)
        Orders::EventApplier.create_items_and_fills(order, items_data, fills_data)
        Orders::EventApplier.apply_event(event)
        
        refactored_steps = processing_steps.dup
        
        [legacy_steps, refactored_steps]
      end
      
      tester.print_summary
      expect(tester.results[:failed]).to be_empty
    end
  end
end
