# frozen_string_literal: true

# 事件总线初始化器
# 配置事件订阅关系

Rails.application.config.after_initialize do
  # 确保在所有类加载完成后再注册订阅者
  
  # 初始化事件总线单例
  Infrastructure::EventBus.instance
  
  # 注册市场数据更新监听器
  market_data_updater = Orders::Events::MarketDataUpdater.new
  Infrastructure::EventBus.subscribe('order.fulfilled', market_data_updater, method_name: :order_fulfilled, async: true)
  Infrastructure::EventBus.subscribe('order.status_updated', market_data_updater, method_name: :order_status_updated, async: true)
  Infrastructure::EventBus.subscribe('order.matched', market_data_updater, method_name: :order_matched, async: true)
  
  # 注册广播通知监听器
  realtime_notifier = Orders::Events::RealtimeNotifier.new
  Infrastructure::EventBus.subscribe('order.fulfilled', realtime_notifier, method_name: :order_fulfilled, async: true)
  Infrastructure::EventBus.subscribe('order.status_updated', realtime_notifier, method_name: :order_status_updated, async: true)
  Infrastructure::EventBus.subscribe('order.matched', realtime_notifier, method_name: :order_matched, async: true)
  
  # 注册分析数据跟踪监听器
  analytics_tracker = Orders::Events::AnalyticsTracker.new
  Infrastructure::EventBus.subscribe('order.fulfilled', analytics_tracker, method_name: :order_fulfilled, async: true)
  Infrastructure::EventBus.subscribe('order.status_updated', analytics_tracker, method_name: :order_status_updated, async: true)
  Infrastructure::EventBus.subscribe('order.matched', analytics_tracker, method_name: :order_matched, async: true)
  
  Rails.logger.info "[Infrastructure::EventBus] Initialized with #{Infrastructure::EventBus.instance.subscriber_count} total subscriptions"
  
  # 输出订阅关系调试信息
  if Rails.logger.level <= Logger::DEBUG
    Infrastructure::EventBus.instance.debug_subscriptions.each do |event_name, subscribers|
      Rails.logger.debug "[Infrastructure::EventBus] Event '#{event_name}' has #{subscribers.size} subscribers"
    end
  end
end
