# frozen_string_literal: true

module Strategies
  # 调度策略基类
  class BaseSchedulingStrategy
    include ::MarketData::TimeAlignment

    def initialize
      # 不再存储 Redis 连接实例，使用 Sidekiq.redis 连接池
    end

    # 子类需要实现的方法
    def get_pending_tasks
      raise NotImplementedError, "Subclasses must implement get_pending_tasks"
    end

    # 获取该策略处理的topic类型
    def topic_types
      raise NotImplementedError, "Subclasses must implement topic_types"
    end

    protected

    # 获取活跃的订阅
    def get_active_subscriptions(pattern = "*")
      # 使用新的SubscriptionManager获取活跃主题
      Realtime::SubscriptionManager.get_active_topics(pattern)
    end

    # 检查topic是否需要调度
    def should_schedule_topic?(topic, current_time)
      parsed = ::Realtime::TopicParser.parse_topic(topic)
      return false unless parsed
      return false unless topic_types.include?(parsed[:topic_type])

      interval = parsed[:interval]
      return false if interval.nil? || interval.zero?

      # 检查是否到达对齐时间
      next_aligned_key = "next_aligned_ts:#{topic}"
      next_aligned_val = Sidekiq.redis { |conn| conn.get(next_aligned_key) }

      if next_aligned_val.nil?
        # 初始化对齐时间，使用 SET EX 原子操作设置 TTL
        init_ts = align_to_interval(current_time, interval)
        Sidekiq.redis { |conn| conn.set(next_aligned_key, init_ts, ex: RuntimeCache::Keyspace::DEFAULT_NEXT_ALIGNED_TTL) }
        return false
      end

      next_aligned_ts = next_aligned_val.to_i

      if current_time >= next_aligned_ts
        # 更新下一次对齐时间，刷新 TTL
        new_aligned_ts = next_aligned_ts + interval * 60
        Sidekiq.redis { |conn| conn.set(next_aligned_key, new_aligned_ts, ex: RuntimeCache::Keyspace::DEFAULT_NEXT_ALIGNED_TTL) }
        return true
      end

      false
    end
    
    # 创建广播任务
    def create_broadcast_task(type, params)
      {
        type: type,
        params: params,
        created_at: Time.current.to_i
      }
    end
    
    # 批量创建任务
    def create_batch_tasks(type, items)
      return [] if items.empty?
      
      # 按市场分组以优化性能
      grouped_items = items.group_by do |item|
        if item.is_a?(Array)
          ::Realtime::TopicParser.parse_topic(item[0])&.dig(:market_id)
        else
          item[:market_id]
        end
      end
      
      grouped_items.map do |market_id, market_items|
        create_broadcast_task(type, { batch: market_items })
      end
    end
    
    # 记录调度统计
    def log_scheduling_stats(strategy_name, tasks_count)
      Rails.logger.info "[Scheduling] #{strategy_name}: scheduled #{tasks_count} tasks"
    end
    
    # 是否需要心跳机制（子类重写）
    def needs_heartbeat?
      false
    end
    
    # 心跳间隔（秒），默认30秒
    def heartbeat_interval
      30
    end
  end
end
