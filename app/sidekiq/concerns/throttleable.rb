# frozen_string_literal: true

# Throttleable Concern - 通用调度任务节流机制
#
# 用途：防止 Sidekiq Scheduler 积压任务一次性释放导致连接池耗尽
# 适用场景：周期性调度任务（MarketData::Broadcast::DispatcherJob, EventCollectorJob, InstanceMetadataScannerJob 等）
# 不适用：一次性事务任务（订单处理、回调等）
#
# 使用示例：
#   class MySchedulerJob
#     include Sidekiq::Job
#     include Throttleable
#
#     throttle interval: 2.0  # 2秒内不重复执行
#
#     def perform
#       return if should_throttle?  # 检查是否应该跳过
#       # ... 任务逻辑 ...
#     end
#   end
#
module Throttleable
  extend ActiveSupport::Concern

  included do
    class_attribute :throttle_interval, default: 0.5  # 秒
    class_attribute :throttle_ttl, default: 10        # Redis key TTL
  end

  class_methods do
    # 配置节流参数
    # @param interval [Float] 最小执行间隔（秒）
    # @param ttl [Integer] Redis key 过期时间（秒），建议设置为 interval 的 2-3 倍
    def throttle(interval: 0.5, ttl: 10)
      self.throttle_interval = interval
      self.throttle_ttl = ttl
    end
  end

  private

  # 检查是否应该跳过执行
  # @return [Boolean] true = 应该跳过，false = 可以执行
  def should_throttle?
    return false if throttle_interval <= 0

    key = throttle_redis_key
    now = Time.now.to_f

    # ⭐ 使用 Sidekiq.redis 复用连接池（5-10 连接）
    # 而不是 Redis.current（单连接），提高并发性能
    last_run = Sidekiq.redis { |conn| conn.get(key) }.to_f

    if now - last_run < throttle_interval
      elapsed_ms = ((now - last_run) * 1000).round
      Rails.logger.debug "[#{self.class.name}] 距上次执行 #{elapsed_ms}ms，跳过积压任务"
      return true
    end

    # 更新执行时间（SET EX：SET + EXPIRE 原子操作）
    Sidekiq.redis { |conn| conn.set(key, now.to_s, ex: throttle_ttl) }
    false
  end

  def throttle_redis_key
    # 使用 Sidekiq namespace 感知的 key 命名
    # 示例：sidekiq:throttle:jobs:broadcast:dispatcher_job
    "sidekiq:throttle:#{self.class.name.underscore.gsub('/', ':')}"
  end
end
