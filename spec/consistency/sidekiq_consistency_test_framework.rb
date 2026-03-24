# frozen_string_literal: true

# Sidekiq重构一致性测试框架
# 用于验证重构前后的行为一致性
module SidekiqConsistencyTestFramework
  class ConsistencyTester
    attr_reader :results
    
    def initialize
      @results = {
        passed: [],
        failed: [],
        errors: []
      }
    end
    
    # 对比测试主方法
    def compare_behaviors(test_name, &block)
      puts "\n=== Running consistency test: #{test_name} ==="
      
      begin
        # 执行测试块并收集结果
        legacy_result, refactored_result = block.call
        
        # 对比结果
        if results_equal?(legacy_result, refactored_result)
          @results[:passed] << test_name
          puts "✅ PASS: #{test_name}"
        else
          @results[:failed] << {
            test: test_name,
            legacy: legacy_result,
            refactored: refactored_result
          }
          puts "❌ FAIL: #{test_name}"
          puts "  Legacy:     #{legacy_result.inspect}"
          puts "  Refactored: #{refactored_result.inspect}"
        end
        
      rescue => e
        @results[:errors] << {
          test: test_name,
          error: e.message,
          backtrace: e.backtrace.first(5)
        }
        puts "🔥 ERROR: #{test_name} - #{e.message}"
      end
    end
    
    # 打印测试总结
    def print_summary
      puts "\n" + "="*60
      puts "CONSISTENCY TEST SUMMARY"
      puts "="*60
      
      puts "✅ Passed: #{@results[:passed].size}"
      @results[:passed].each { |test| puts "   - #{test}" }
      
      puts "\n❌ Failed: #{@results[:failed].size}"
      @results[:failed].each do |failure|
        puts "   - #{failure[:test]}"
      end
      
      puts "\n🔥 Errors: #{@results[:errors].size}"
      @results[:errors].each do |error|
        puts "   - #{error[:test]}: #{error[:error]}"
      end
      
      puts "\nTotal: #{total_tests} tests"
      puts "Success Rate: #{success_rate.round(2)}%"
    end
    
    private
    
    def results_equal?(legacy, refactored)
      # 深度对比两个结果
      case legacy
      when Hash
        return false unless refactored.is_a?(Hash)
        legacy.keys.sort == refactored.keys.sort &&
          legacy.all? { |k, v| results_equal?(v, refactored[k]) }
      when Array
        return false unless refactored.is_a?(Array)
        legacy.size == refactored.size &&
          legacy.zip(refactored).all? { |a, b| results_equal?(a, b) }
      when Float
        return false unless refactored.is_a?(Numeric)
        (legacy - refactored).abs < 0.0001  # 浮点数精度容差
      else
        legacy == refactored
      end
    end
    
    def total_tests
      @results[:passed].size + @results[:failed].size + @results[:errors].size
    end
    
    def success_rate
      return 0 if total_tests.zero?
      (@results[:passed].size.to_f / total_tests) * 100
    end
  end
  
  # 测试数据生成器
  class TestDataGenerator
    def self.create_test_order_fill(market_id: 'ETH-USD', filled_amount: 100.0)
      # 创建测试用的OrderFill记录
      order = create(:trading_order, market_id: market_id)
      
      create(:trading_order_fill,
        order: order,
        market_id: market_id,
        filled_amount: filled_amount,
        total_amount: 1500.0,  # 模拟价格分布数据
        created_at: Time.current
      )
    end
    
    def self.create_test_market_data(market_id)
      {
        market_id: market_id,
        close: "1500.0",
        vol: "100.0",
        time: Time.current.to_i.to_s
      }
    end
    
    def self.create_test_kline_params(market_id, interval = 60)
      {
        market_id: market_id,
        interval: interval,
        start_time: 1.hour.ago.to_i,
        end_time: Time.current.to_i
      }
    end
    
    # 实例方法，用于事件处理测试
    def generate_items_data
      [
        {
          "token_address" => "0xtoken123",
          "token_id" => "1", 
          "item_type" => "ERC721",
          "amount" => "1"
        }
      ]
    end
    
    def generate_fills_data
      [
        {
          "price_distribution" => [
            {
              "total_amount" => "1500.0",
              "filled_amount" => "100.0"
            }
          ],
          "filled_amount" => "100.0",
          "order_item_index" => 0
        }
      ]
    end
  end
  
  # Redis状态对比器
  class RedisStateComparator
    def self.compare_redis_state(keys_pattern, &block)
      # 记录Redis状态变化前后
      before_state = capture_redis_state(keys_pattern)
      
      result = block.call
      
      after_state = capture_redis_state(keys_pattern)
      
      {
        result: result,
        redis_changes: calculate_changes(before_state, after_state)
      }
    end
    
    private
    
    def self.capture_redis_state(pattern)
      keys = Redis.current.keys(pattern)
      state = {}
      
      keys.each do |key|
        type = Redis.current.type(key)
        case type
        when 'string'
          state[key] = Redis.current.get(key)
        when 'hash'
          state[key] = Redis.current.hgetall(key)
        when 'list'
          state[key] = Redis.current.lrange(key, 0, -1)
        when 'set'
          state[key] = Redis.current.smembers(key)
        when 'zset'
          state[key] = Redis.current.zrange(key, 0, -1, with_scores: true)
        end
      end
      
      state
    end
    
    def self.calculate_changes(before, after)
      changes = {}
      
      # 检查新增的键
      (after.keys - before.keys).each do |key|
        changes[key] = { action: 'added', value: after[key] }
      end
      
      # 检查删除的键
      (before.keys - after.keys).each do |key|
        changes[key] = { action: 'deleted', value: before[key] }
      end
      
      # 检查修改的键
      (before.keys & after.keys).each do |key|
        unless before[key] == after[key]
          changes[key] = {
            action: 'modified',
            before: before[key],
            after: after[key]
          }
        end
      end
      
      changes
    end
  end
end