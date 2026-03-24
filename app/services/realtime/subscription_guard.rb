# frozen_string_literal: true

module Realtime
  # 统一处理订阅检查的入口，带降级与告警
  module SubscriptionGuard
    DEFAULT_DEPTH_LIMITS = [5, 10, 20, 50].freeze

    module_function

    # 检查通道是否有订阅；Redis/服务异常时默认返回 true 以兜底广播
    def has_subscribers?(channel)
      return true if channel.blank?

      Realtime::SubscriptionManager.has_subscribers?(channel)
    rescue StandardError => e
      Rails.logger.warn("[SubscriptionGuard] fallback to broadcast for #{channel}: #{e.message}")
      true
    end

    # 获取某个市场的深度订阅档位；异常时返回默认档位以保障广播
    def depth_limits_for_market(market_id)
      return DEFAULT_DEPTH_LIMITS if market_id.blank?

      keys = Redis.current.keys("sub_count:#{market_id}@DEPTH_*")
      return [] if keys.empty?

      limits = keys.filter_map do |key|
        sub_count = Redis.current.get(key).to_i
        next if sub_count < 1
        depth_str = key.split("@DEPTH_").last
        depth_str.to_i if depth_str.present?
      end

      limits.uniq
    rescue StandardError => e
      Rails.logger.warn("[SubscriptionGuard] depth_limits fallback for market #{market_id}: #{e.message}")
      DEFAULT_DEPTH_LIMITS
    end
  end
end
