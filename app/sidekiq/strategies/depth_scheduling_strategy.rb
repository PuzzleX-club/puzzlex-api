# frozen_string_literal: true

module Strategies
  # 深度数据调度策略
  # 实现定时心跳机制，确保深度数据保持"活跃"状态
  class DepthSchedulingStrategy < BaseSchedulingStrategy
    # 心跳间隔：30秒
    HEARTBEAT_INTERVAL = 30
    
    def topic_types
      ['DEPTH']
    end
    
    def get_pending_tasks
      current_time = Time.now.to_i
      tasks = []
      
      # 获取所有活跃的深度订阅
      active_depth_subscriptions = get_active_depth_subscriptions
      
      # 为每个市场的深度订阅生成心跳任务
      active_depth_subscriptions.each do |market_id, limits|
        # 检查是否需要发送心跳
        if should_send_heartbeat?(market_id, current_time)
          # 为该市场的所有深度级别创建广播任务
          limits.each do |limit|
            tasks << create_depth_heartbeat_task(market_id, limit)
          end
          
          # 更新心跳时间戳
          update_heartbeat_timestamp(market_id, current_time)
        end
      end
      
      log_scheduling_stats('DepthScheduling', tasks.size)
      
      tasks
    end
    
    private
    
    # 获取所有活跃的深度订阅，按市场分组
    def get_active_depth_subscriptions
      subscriptions = {}

      # 查找所有深度订阅 (格式: MARKET_ID@DEPTH_LIMIT)
      depth_keys = Sidekiq.redis { |conn| conn.keys("sub_count:*@DEPTH_*") }

      depth_keys.each do |key|
        sub_count = Sidekiq.redis { |conn| conn.get(key) }.to_i
        next unless sub_count > 0

        # 解析市场ID和深度限制
        topic = key.sub("sub_count:", "")
        if topic =~ /^(.+)@DEPTH_(\d+)$/
          market_id = $1
          limit = $2.to_i

          subscriptions[market_id] ||= []
          subscriptions[market_id] << limit
        end
      end

      subscriptions
    end

    # 检查是否应该发送心跳
    def should_send_heartbeat?(market_id, current_time)
      heartbeat_key = "depth_heartbeat:#{market_id}"
      last_heartbeat = Sidekiq.redis { |conn| conn.get(heartbeat_key) }

      # 如果没有记录或超过心跳间隔，则需要发送
      return true if last_heartbeat.nil?

      (current_time - last_heartbeat.to_i) >= HEARTBEAT_INTERVAL
    end

    # 更新心跳时间戳
    def update_heartbeat_timestamp(market_id, current_time)
      heartbeat_key = "depth_heartbeat:#{market_id}"
      Sidekiq.redis { |conn| conn.set(heartbeat_key, current_time, ex: HEARTBEAT_INTERVAL * 2) }
    end
    
    # 创建深度心跳任务
    def create_depth_heartbeat_task(market_id, limit)
      {
        type: 'depth',
        params: {
          market_id: market_id,
          limit: limit,
          is_heartbeat: true  # 标记为心跳广播
        },
        created_at: Time.current.to_i
      }
    end
  end
end