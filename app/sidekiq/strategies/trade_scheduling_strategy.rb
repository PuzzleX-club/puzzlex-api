# frozen_string_literal: true

module Strategies
  # 成交数据调度策略
  class TradeSchedulingStrategy < BaseSchedulingStrategy
    def topic_types
      ['TRADE']
    end
    
    def get_pending_tasks
      current_time = Time.now.to_i
      
      # 获取TRADE相关的活跃订阅
      active_topics = get_active_subscriptions("*@TRADE*")
      
      # TRADE通常是实时的，不需要时间对齐
      # 从master dispatcher触发，时间为0代表从master入口推送
      realtime_trades = active_topics.map { |topic| [topic, 0] }
      
      tasks = []
      
      # 创建成交批量任务
      unless realtime_trades.empty?
        tasks += create_batch_tasks('trade_batch', realtime_trades)
      end
      
      log_scheduling_stats('TradeScheduling', tasks.size)
      
      tasks
    end
  end
end