# frozen_string_literal: true

# ==================== Trade心跳策略 ====================
#
# ⚠️ 当前已禁用
#
# 【禁用原因】
# Trade 数据改为增量广播架构后，不再需要定时心跳：
# - 每次成交发生时立即推送（事件驱动，500ms聚合延迟）
# - 时间窗口聚合（5秒锁定期）避免高频推送
# - 无长时间静默期，无需心跳保活WebSocket连接
#
# 【心跳机制说明】
# - Depth 数据仍使用心跳（DepthSchedulingStrategy）- 长时间无订单变化时需要保活
# - Kline/Ticker 使用定时广播（1分钟/30秒），无需额外心跳
# - Trade 在旧的批量广播模式下才需要心跳（TradeBatchStrategy）
#
# 【何时需要启用】
# 如果未来重新启用 TradeBatchStrategy（批量广播模式），
# 则需要启用本策略来保持WebSocket连接活跃：
# 1. 在调度系统中注册本策略
# 2. 配置30秒心跳间隔
# 3. 确保 TradeBatchStrategy 支持 is_heartbeat 参数
#
# ==================== 代码开始 ====================

module Strategies
  # Trade广播心跳策略（旧实现，已禁用）
  # 为Trade订阅提供30秒心跳机制，确保连接保持活跃
  class TradeHeartbeatStrategy < BaseSchedulingStrategy
    # 心跳间隔：30秒
    HEARTBEAT_INTERVAL = 30
    
    def topic_types
      ['TRADE']
    end
    
    def needs_heartbeat?
      true
    end
    
    def heartbeat_interval
      HEARTBEAT_INTERVAL
    end
    
    def get_pending_tasks
      current_time = Time.current.to_i
      tasks = []
      
      # 获取所有活跃的Trade订阅
      active_trade_subscriptions = get_active_trade_subscriptions
      
      # 为每个市场的Trade订阅生成心跳任务
      active_trade_subscriptions.each do |market_id|
        topic_key = "trade:#{market_id}"
        
        # 检查是否需要发送心跳
        if Realtime::HeartbeatService.should_send_heartbeat?(topic_key, HEARTBEAT_INTERVAL)
          # 避免与最近的数据更新冲突
          unless Realtime::HeartbeatService.recently_sent_heartbeat?(topic_key, 5)
            tasks << create_trade_heartbeat_task(market_id)
            
            # 注意：不在这里记录心跳时间，而是在实际广播时记录
            # Realtime::HeartbeatService.record_heartbeat 将在 UnifiedBroadcastWorker 中调用
          end
        end
      end
      
      log_scheduling_stats('TradeHeartbeat', tasks.size)
      
      tasks
    end
    
    private
    
    # 获取所有活跃的Trade订阅，按市场分组
    def get_active_trade_subscriptions
      markets = []

      # 查找所有Trade订阅 (格式: MARKET_ID@TRADE)
      trade_keys = Sidekiq.redis { |conn| conn.keys("sub_count:*@TRADE") }

      trade_keys.each do |key|
        sub_count = Sidekiq.redis { |conn| conn.get(key) }.to_i
        next unless sub_count > 0

        # 解析市场ID
        topic = key.sub("sub_count:", "")
        if topic =~ /^(.+)@TRADE$/
          market_id = $1
          markets << market_id
        end
      end

      markets.uniq
    end
    
    # 创建Trade心跳任务
    def create_trade_heartbeat_task(market_id)
      {
        type: 'trade_batch',
        params: {
          batch: [["#{market_id}@TRADE", Time.current.to_i]],
          is_heartbeat: true  # 标记为心跳广播
        },
        created_at: Time.current.to_i
      }
    end
  end
end
