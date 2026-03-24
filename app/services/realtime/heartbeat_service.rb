# frozen_string_literal: true

module Realtime
  # 通用心跳服务
  # 提供统一的心跳时间管理，支持多种广播类型
  class HeartbeatService
    class << self
      def record_update(topic)
        redis_key = "heartbeat_last_update:#{topic}"
        current_time = Time.current.to_i

        Redis.current.set(redis_key, current_time, ex: 7200)
        Rails.logger.debug "[Realtime::HeartbeatService] Recorded update for #{topic} at #{current_time}"
      end

      def last_update_time(topic)
        redis_key = "heartbeat_last_update:#{topic}"
        last_update = Redis.current.get(redis_key)

        last_update&.to_i
      end

      def should_send_heartbeat?(topic, interval)
        current_time = Time.current.to_i
        last_update = last_update_time(topic)
        last_heartbeat = last_heartbeat_time(topic)
        last_activity = [last_update, last_heartbeat].compact.max

        return true if last_activity.nil?

        (current_time - last_activity) >= interval
      end

      def record_heartbeat(topic)
        redis_key = "heartbeat_sent:#{topic}"
        current_time = Time.current.to_i

        Redis.current.set(redis_key, current_time, ex: 7200)
        Rails.logger.debug "[Realtime::HeartbeatService] Recorded heartbeat for #{topic} at #{current_time}"
      end

      def last_heartbeat_time(topic)
        redis_key = "heartbeat_sent:#{topic}"
        last_heartbeat = Redis.current.get(redis_key)

        last_heartbeat&.to_i
      end

      def recently_sent_heartbeat?(topic, grace_period = 5)
        last_heartbeat = last_heartbeat_time(topic)
        return false if last_heartbeat.nil?

        current_time = Time.current.to_i
        (current_time - last_heartbeat) < grace_period
      end

      def cleanup_expired_records(topics = [])
        patterns = if topics.empty?
                     ['heartbeat_last_update:*', 'heartbeat_sent:*']
                   else
                     topics.flat_map do |topic|
                       ["heartbeat_last_update:#{topic}", "heartbeat_sent:#{topic}"]
                     end
                   end

        total_cleaned = 0
        patterns.each do |pattern|
          if pattern.include?('*')
            keys = Redis.current.keys(pattern)
            unless keys.empty?
              cleaned = Redis.current.del(*keys)
              total_cleaned += cleaned
            end
          elsif Redis.current.exists(pattern)
            Redis.current.del(pattern)
            total_cleaned += 1
          end
        end

        Rails.logger.info "[Realtime::HeartbeatService] Cleaned #{total_cleaned} expired heartbeat records"
        total_cleaned
      end
    end
  end
end
