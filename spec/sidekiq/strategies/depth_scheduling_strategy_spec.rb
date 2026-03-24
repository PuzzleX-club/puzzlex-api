require 'rails_helper'

RSpec.describe Strategies::DepthSchedulingStrategy do
  let(:strategy) { described_class.new }
  let(:redis) { Redis.current }
  
  before do
    # 清理测试相关的Redis键
    redis.keys("sub_count:*@DEPTH_*").each { |key| redis.del(key) }
    redis.keys("depth_heartbeat:*").each { |key| redis.del(key) }
  end
  
  describe '#get_pending_tasks' do
    context '当没有活跃订阅时' do
      it '返回空任务列表' do
        tasks = strategy.get_pending_tasks
        expect(tasks).to be_empty
      end
    end
    
    context '当有活跃的深度订阅时' do
      before do
        # 模拟活跃订阅
        redis.set("sub_count:BTCUSDT@DEPTH_10", 2)
        redis.set("sub_count:BTCUSDT@DEPTH_20", 1)
        redis.set("sub_count:ETHUSDT@DEPTH_10", 3)
      end
      
      context '首次运行（无心跳记录）' do
        it '为所有市场生成心跳任务' do
          tasks = strategy.get_pending_tasks
          
          expect(tasks.size).to eq(3)
          
          # 检查BTCUSDT的任务
          btc_tasks = tasks.select { |t| t[:params][:market_id] == 'BTCUSDT' }
          expect(btc_tasks.size).to eq(2)
          expect(btc_tasks.map { |t| t[:params][:limit] }).to contain_exactly(10, 20)
          
          # 检查ETHUSDT的任务
          eth_tasks = tasks.select { |t| t[:params][:market_id] == 'ETHUSDT' }
          expect(eth_tasks.size).to eq(1)
          expect(eth_tasks.first[:params][:limit]).to eq(10)
          
          # 验证所有任务都标记为心跳
          tasks.each do |task|
            expect(task[:type]).to eq('depth')
            expect(task[:params][:is_heartbeat]).to be true
          end
        end
        
        it '更新心跳时间戳' do
          strategy.get_pending_tasks
          
          expect(redis.get("depth_heartbeat:BTCUSDT")).not_to be_nil
          expect(redis.get("depth_heartbeat:ETHUSDT")).not_to be_nil
        end
      end
      
      context '心跳间隔内再次运行' do
        before do
          # 设置最近的心跳时间
          current_time = Time.now.to_i
          redis.setex("depth_heartbeat:BTCUSDT", 60, current_time)
          redis.setex("depth_heartbeat:ETHUSDT", 60, current_time)
        end
        
        it '不生成新的心跳任务' do
          tasks = strategy.get_pending_tasks
          expect(tasks).to be_empty
        end
      end
      
      context '超过心跳间隔后运行' do
        before do
          # 设置31秒前的心跳时间
          old_time = Time.now.to_i - 31
          redis.setex("depth_heartbeat:BTCUSDT", 60, old_time)
          redis.setex("depth_heartbeat:ETHUSDT", 60, old_time)
        end
        
        it '生成新的心跳任务' do
          tasks = strategy.get_pending_tasks
          expect(tasks.size).to eq(3)
        end
      end
    end
    
    context '当订阅数为0时' do
      before do
        # 设置订阅数为0
        redis.set("sub_count:BTCUSDT@DEPTH_10", 0)
      end
      
      it '不生成心跳任务' do
        tasks = strategy.get_pending_tasks
        expect(tasks).to be_empty
      end
    end
  end
  
  describe '心跳间隔常量' do
    it '设置为30秒' do
      expect(described_class::HEARTBEAT_INTERVAL).to eq(30)
    end
  end
end