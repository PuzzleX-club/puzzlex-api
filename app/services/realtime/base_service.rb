# frozen_string_literal: true

module Realtime
  # 广播服务基类
  # 提供统一的广播接口、订阅检查、错误处理和性能监控
  class BaseService
    class << self
      # 广播数据到指定频道
      # @param channel [String] 频道名称
      # @param data [Hash] 要广播的数据
      # @param options [Hash] 可选参数
      # @return [Boolean] 广播是否成功
      def broadcast(channel, data, options = {})
        return false unless should_broadcast?(channel, options)
        
        start_time = Time.current
        
        begin
          formatted_data = format_data(channel, data, options)
          ActionCable.server.broadcast(channel, formatted_data)
          
          track_success(channel, start_time)
          log_broadcast(channel, formatted_data, options)
          
          true
        rescue => e
          track_error(channel, e)
          handle_error(e, channel, data)
          
          false
        end
      end
      
      # 批量广播
      # @param broadcasts [Array<Hash>] [{channel: 'xxx', data: {...}}, ...]
      # @return [Hash] { success: [], failed: [] }
      def batch_broadcast(broadcasts)
        results = { success: [], failed: [] }
        
        broadcasts.each do |broadcast_item|
          channel = broadcast_item[:channel]
          data = broadcast_item[:data]
          options = broadcast_item[:options] || {}
          
          if broadcast(channel, data, options)
            results[:success] << channel
          else
            results[:failed] << channel
          end
        end
        
        results
      end
      
      # 检查频道是否有活跃订阅
      # @param channel [String] 频道名称
      # @return [Boolean] 是否有活跃订阅
      def has_active_subscriptions?(channel)
        # 检查新系统（Redis Set）
        new_count = Redis.current.scard("topic:#{channel}:subscribers")
        # 检查旧系统（计数器）
        old_count = Redis.current.get("sub_count:#{channel}").to_i
        # TODO: 后续完全迁移到新订阅系统后，移除旧系统检查（old_count）
        # 任一系统有订阅者即返回true（兼容过渡期）
        (new_count + old_count) > 0
      end
      
      # 获取所有活跃订阅的频道
      # @param pattern [String] 频道模式，如 "*@TICKER_*"
      # @return [Array<String>] 活跃频道列表
      def active_channels(pattern = "*")
        keys = Redis.current.keys("sub_count:#{pattern}")
        
        keys.select do |key|
          Redis.current.get(key).to_i > 0
        end.map do |key|
          key.sub("sub_count:", "")
        end
      end
      
      protected
      
      # 子类需要实现的方法
      
      # 格式化数据（子类可以覆盖）
      def format_data(channel, data, options)
        {
          channel: channel,
          data: data,
          timestamp: Time.current.to_i
        }
      end
      
      # 是否应该广播（子类可以覆盖添加额外检查）
      def should_broadcast?(channel, options)
        return true if options[:force] # 强制广播
        
        has_active_subscriptions?(channel)
      end
      
      private
      
      # 记录广播成功
      def track_success(channel, start_time)
        duration = (Time.current - start_time) * 1000 # 毫秒
        
        # 可以集成 Prometheus 或其他监控系统
        Rails.logger.info "[Realtime] Success: channel=#{channel}, duration=#{duration}ms"
      end
      
      # 记录广播错误
      def track_error(channel, error)
        Rails.logger.error "[Realtime] Error: channel=#{channel}, error=#{error.class.name}, message=#{error.message}"
      end
      
      # 记录广播日志
      def log_broadcast(channel, data, options)
        return unless options[:debug] || Rails.env.development?
        
        Rails.logger.debug "[Realtime] channel=#{channel}, data_size=#{data.to_json.size} bytes"
      end
      
      # 错误处理
      def handle_error(error, channel, data)
        # 可以发送到错误跟踪系统（如 Sentry）
        Rails.logger.error "[Realtime] Failed to broadcast to #{channel}: #{error.message}"
        Rails.logger.error error.backtrace.join("\n") if Rails.env.development?
      end
    end
  end
end