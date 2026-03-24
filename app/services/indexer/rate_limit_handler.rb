# frozen_string_literal: true

module Indexer
  # 智能限流处理器
  # 所有配置通过 Rails config 注入；canonical source 为
  # config.x.instance_metadata（from instance_metadata.rb initializer）
  #
  class RateLimitHandler
    REDIS_KEY_PREFIX = 'indexer:metadata:'
    RATE_LIMIT_KEY = "#{REDIS_KEY_PREFIX}rate_limited"
    BATCH_SIZE_KEY = "#{REDIS_KEY_PREFIX}batch_size"
    CONSECUTIVE_SUCCESS_KEY = "#{REDIS_KEY_PREFIX}consecutive_success"

    class << self
      # ========================================
      # 公共 API
      # ========================================

      # 获取当前动态批次大小
      # @return [Integer] 当前批次大小
      def current_batch_size
        # 如果正在限流中，使用最小批次
        return min_batch_size if rate_limited?

        # 读取动态 batch_size，默认使用配置值
        cached = redis.get(BATCH_SIZE_KEY)
        cached ? cached.to_i : default_batch_size
      end

      # 触发限流
      # @param retry_after [Integer, nil] Retry-After 响应头的值（秒）
      # @param reason [String] 限流原因（用于日志和调试）
      def on_rate_limited!(retry_after: nil, reason: 'unknown')
        cooldown = retry_after || default_cooldown_seconds
        current = current_batch_size

        # 设置限流标记（存储原因，便于调试）
        redis.set(RATE_LIMIT_KEY, reason, ex: cooldown)

        # 降低 batch_size
        new_size = [current - step_size, min_batch_size].max
        redis.set(BATCH_SIZE_KEY, new_size, ex: cooldown + 300) # 限流结束后再保持5分钟

        # 重置连续成功计数
        redis.del(CONSECUTIVE_SUCCESS_KEY)

        Rails.logger.warn "[RateLimitHandler] 限流触发 reason=#{reason}, cooldown=#{cooldown}s, batch_size: #{current} -> #{new_size}"
      end

      # 请求成功时调用，用于恢复批次大小
      def on_success!
        # 如果还在限流冷却中，不做任何操作
        return if rate_limited?

        current = current_batch_size
        return if current >= default_batch_size

        # 增加连续成功计数
        success_count = redis.incr(CONSECUTIVE_SUCCESS_KEY)
        redis.expire(CONSECUTIVE_SUCCESS_KEY, 300) # 5分钟过期

        # 达到阈值后尝试恢复 batch_size
        if success_count >= recovery_threshold
          new_size = [current + step_size, default_batch_size].min
          redis.setex(BATCH_SIZE_KEY, 600, new_size) # 10分钟后过期
          redis.del(CONSECUTIVE_SUCCESS_KEY)
          Rails.logger.info "[RateLimitHandler] 恢复 batch_size: #{current} -> #{new_size} (连续成功#{success_count}次)"
        end
      end

      # 检查是否正在限流中
      # @return [Boolean]
      def rate_limited?
        redis.exists?(RATE_LIMIT_KEY)
      end

      # 获取限流剩余时间
      # @return [Integer] 剩余秒数，-2 表示不存在
      def rate_limit_ttl
        redis.ttl(RATE_LIMIT_KEY)
      end

      # 状态信息（用于监控/调试）
      # @return [Hash] 完整状态信息
      def status
        {
          rate_limited: rate_limited?,
          rate_limit_ttl: rate_limit_ttl,
          rate_limit_reason: redis.get(RATE_LIMIT_KEY),
          current_batch_size: current_batch_size,
          default_batch_size: default_batch_size,
          min_batch_size: min_batch_size,
          step_size: step_size,
          recovery_threshold: recovery_threshold,
          consecutive_success: redis.get(CONSECUTIVE_SUCCESS_KEY)&.to_i || 0,
          simple_mode: simple_rate_limit_mode?,
          empty_as_limit: empty_response_as_rate_limit?
        }
      end

      # ========================================
      # 配置读取（统一走 Rails config）
      # ========================================

      # 简单限流模式：任何非200响应都视为限流
      # @return [Boolean]
      def simple_rate_limit_mode?
        instance_metadata_config.simple_rate_limit
      end

      # 空数据也视为限流
      # @return [Boolean]
      def empty_response_as_rate_limit?
        instance_metadata_config.empty_as_rate_limit
      end

      # 默认批次大小
      # @return [Integer]
      def default_batch_size
        instance_metadata_config.batch_size
      end

      # 最小批次大小
      # @return [Integer]
      def min_batch_size
        instance_metadata_config.batch_size_min
      end

      # 调整步长
      # @return [Integer]
      def step_size
        instance_metadata_config.batch_size_step
      end

      # 默认冷却时间（秒）
      # @return [Integer]
      def default_cooldown_seconds
        instance_metadata_config.rate_limit_cooldown
      end

      # 恢复阈值（连续成功次数）
      # @return [Integer]
      def recovery_threshold
        instance_metadata_config.recovery_threshold
      end

      private

      def instance_metadata_config
        Rails.application.config.x.instance_metadata
      end

      def redis
        Redis.current
      end
    end
  end
end
