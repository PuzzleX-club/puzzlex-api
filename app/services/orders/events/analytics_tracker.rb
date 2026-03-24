# frozen_string_literal: true

module Orders
  module Events
    # 分析数据跟踪监听器
    # 监听订单事件，收集分析数据和指标
    class AnalyticsTracker
    # 处理订单履行事件
    def order_fulfilled(event)
      data = event.data
      
      Rails.logger.info "[Orders::Events::AnalyticsTracker] Tracking order.fulfilled event #{data[:event_id]}"
      
      # 更新市场活跃度指标
      track_market_activity(data[:market_id], data[:fills_count])
      
      # 记录交易量指标
      track_trading_volume(data[:market_id], data[:timestamp])
      
      # 更新实时统计
      update_realtime_stats(data)
    end
    
    # 处理订单状态更新事件
    def order_status_updated(event)
      data = event.data
      
      Rails.logger.info "[Orders::Events::AnalyticsTracker] Tracking order.status_updated: #{data[:old_status]} -> #{data[:new_status]}"
      
      # 跟踪订单状态转换
      track_order_status_transition(data[:old_status], data[:new_status])
      
      # 更新完成率指标
      if data[:new_status] == 'filled'
        track_order_completion(data[:market_id])
      end
    end
    
    # 处理订单匹配事件
    def order_matched(event)
      data = event.data
      
      Rails.logger.info "[Orders::Events::AnalyticsTracker] Tracking order.matched event #{data[:event_id]}"
      
      # 跟踪撮合效率
      track_matching_efficiency(data)
      
      # 更新匹配统计
      track_daily_matches
    end
    
    private
    
    def track_market_activity(market_id, fills_count)
      # 使用Redis记录市场活跃度
      today_key = "analytics:market_activity:#{market_id}:#{Date.current.strftime('%Y%m%d')}"
      
      Redis.current.incrby(today_key, fills_count)
      Redis.current.expire(today_key, 7.days.to_i) # 保留7天
      
      # 更新小时级别统计
      hour_key = "analytics:market_activity:#{market_id}:#{Time.current.strftime('%Y%m%d%H')}"
      Redis.current.incrby(hour_key, fills_count)
      Redis.current.expire(hour_key, 3.days.to_i) # 保留3天
    end
    
    def track_trading_volume(market_id, timestamp)
      # 记录交易时间戳用于计算频率
      volume_key = "analytics:trading_volume:#{market_id}"
      
      Redis.current.zadd(volume_key, timestamp, "#{timestamp}_#{SecureRandom.hex(4)}")
      
      # 保留最近24小时的数据
      cutoff_time = 24.hours.ago.to_i
      Redis.current.zremrangebyscore(volume_key, 0, cutoff_time)
    end
    
    def update_realtime_stats(data)
      # 更新全局实时统计
      stats_key = "analytics:realtime_stats"
      
      Redis.current.hincrby(stats_key, "total_fills_today", data[:fills_count])
      Redis.current.hincrby(stats_key, "total_orders_today", 1)
      Redis.current.hset(stats_key, "last_activity", Time.current.to_i)
      
      Redis.current.expire(stats_key, 1.day.to_i)
    end
    
    def track_order_status_transition(old_status, new_status)
      # 记录状态转换统计
      transition_key = "analytics:status_transitions:#{Date.current.strftime('%Y%m%d')}"
      field = "#{old_status}_to_#{new_status}"
      
      Redis.current.hincrby(transition_key, field, 1)
      Redis.current.expire(transition_key, 30.days.to_i)
    end
    
    def track_order_completion(market_id)
      # 记录订单完成情况
      completion_key = "analytics:completions:#{market_id}:#{Date.current.strftime('%Y%m%d')}"
      
      Redis.current.incr(completion_key)
      Redis.current.expire(completion_key, 30.days.to_i)
    end
    
    def track_matching_efficiency(data)
      # 记录撮合事件
      efficiency_key = "analytics:matching:#{Date.current.strftime('%Y%m%d')}"
      
      Redis.current.hincrby(efficiency_key, "total_matches", 1)
      Redis.current.hset(efficiency_key, "last_match_time", Time.current.to_i)
      
      Redis.current.expire(efficiency_key, 30.days.to_i)
    end
    
    def track_daily_matches
      # 更新每日匹配计数
      daily_key = "analytics:daily_matches:#{Date.current.strftime('%Y%m%d')}"
      
      Redis.current.incr(daily_key)
      Redis.current.expire(daily_key, 90.days.to_i)
    end
    end
  end
end
