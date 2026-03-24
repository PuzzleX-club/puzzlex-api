# frozen_string_literal: true

module Strategies
  # 市场数据调度策略
  class MarketSchedulingStrategy < BaseSchedulingStrategy
    def topic_types
      ['MARKET']
    end
    
    def get_pending_tasks
      current_time = Time.now.to_i
      
      # 获取MARKET相关的活跃订阅。
      # topic 命名为 "MARKET@<interval>"（如 MARKET@1440），因此直接匹配前缀即可。
      active_topics = get_active_subscriptions("MARKET@*")
      
      tasks = []
      
      # 处理对齐的MARKET topics
      aligned_topics = active_topics.select do |topic|
        should_schedule_topic?(topic, current_time)
      end
      
      unless aligned_topics.empty?
        # MARKET更新需要调用MarketUpdateJob
        aligned_topics.each do |topic|
          parsed = ::Realtime::TopicParser.parse_topic(topic)
          next unless parsed
          
          # 为每个topic创建MarketUpdateJob任务
          tasks << create_market_update_task(topic, parsed, current_time)
        end
      end
      
      # 处理实时MARKET广播
      realtime_topics = active_topics.select { |topic| topic.include?('realtime') }
      unless realtime_topics.empty?
        realtime_topics.each do |topic|
          tasks << create_broadcast_task('market_realtime', { topic: topic })
        end
      end
      
      log_scheduling_stats('MarketScheduling', tasks.size)
      
      tasks
    end
    
    private
    
    def create_market_update_task(topic, parsed, current_time)
      {
        type: 'market_update',
        params: {
          topic: topic,
          type: 'MARKET',
          is_init: false,
          list_of_pairs: [[topic, current_time]]
        },
        created_at: current_time
      }
    end
  end
end
