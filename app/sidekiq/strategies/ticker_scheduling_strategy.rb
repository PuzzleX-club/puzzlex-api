# frozen_string_literal: true

module Strategies
  # Ticker调度策略
  class TickerSchedulingStrategy < BaseSchedulingStrategy
    def topic_types
      ['TICKER']
    end
    
    def get_pending_tasks
      current_time = Time.now.to_i
      
      # 获取TICKER相关的活跃订阅
      active_topics = get_active_subscriptions("*@TICKER_*")
      
      # 过滤出需要调度的topics
      pending_topics = active_topics.select do |topic|
        should_schedule_topic?(topic, current_time)
      end
      
      tasks = []
      
      # 创建ticker批量任务
      unless pending_topics.empty?
        # 将topics转换为调度格式
        topic_pairs = pending_topics.map { |topic| [topic, current_time] }
        tasks += create_batch_tasks('ticker_batch', topic_pairs)
      end
      
      log_scheduling_stats('TickerScheduling', tasks.size)
      
      tasks
    end
  end
end