# frozen_string_literal: true

module Indexer
  module EventPipeline
    # Token Bucket 限速器
    # 用于控制 RPC 请求频率，避免触发服务端限流
    #
    # 使用方式：
    #   Collector.rate_limiter.acquire  # 获取令牌后再发送请求
    #
    # 特性：
    # - 线程安全（Mutex 保护）
    # - 支持动态 RPS 配置（环境变量）
    # - 精确的等待时间计算
    class RateLimiter
      attr_reader :rps, :tokens

      def initialize(rps: nil)
        default_rps = Rails.application.config.x.log_collector.rps || 5.0
        @rps = (rps || default_rps).to_f
        @tokens = @rps
        @last_refill = Time.now
        @mutex = Mutex.new
      end

      # 获取一个令牌，如果没有可用令牌则等待
      # @return [void]
      def acquire
        @mutex.synchronize do
          loop do
            refill_tokens
            if @tokens >= 1
              @tokens -= 1
              return
            end
            # 精确计算等待时间
            wait_time = (1.0 - @tokens) / @rps
            sleep(wait_time)
          end
        end
      end

      # 尝试获取令牌，不等待
      # @return [Boolean] 是否成功获取令牌
      def try_acquire
        @mutex.synchronize do
          refill_tokens
          if @tokens >= 1
            @tokens -= 1
            true
          else
            false
          end
        end
      end

      # 更新 RPS（用于追赶模式动态调整）
      # @param new_rps [Float] 新的 RPS 值
      def update_rps(new_rps)
        @mutex.synchronize do
          @rps = new_rps.to_f
          # 重新填充到新的上限
          @tokens = [@tokens, @rps].min
        end
      end

      # 获取当前状态（用于日志和监控）
      # @return [Hash] 包含 rps 和 tokens 的状态信息
      def status
        @mutex.synchronize do
          refill_tokens
          { rps: @rps, tokens: @tokens.round(2) }
        end
      end

      private

      def refill_tokens
        now = Time.now
        elapsed = now - @last_refill
        @tokens = [@tokens + elapsed * @rps, @rps].min
        @last_refill = now
      end
    end
  end
end
