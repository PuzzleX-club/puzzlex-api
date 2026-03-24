# frozen_string_literal: true

module Strategies
  # K线调度策略
  class KlineSchedulingStrategy < BaseSchedulingStrategy
    REALTIME_TICK_INTERVAL = 60 # 秒

    def topic_types
      ['KLINE']
    end
    
    def get_pending_tasks
      current_time = Time.now.to_i

      topic_infos = get_active_subscriptions("*@KLINE_*")
        .filter_map { |topic| build_topic_info(topic) }

      realtime_payload = []
      aligned_payload = []

      topic_infos.each do |info|
        if should_schedule_topic?(info[:topic], current_time)
          aligned_ts = aligned_window_end(current_time, info[:interval_minutes])
          aligned_payload << build_task_payload(info, aligned_ts, :aligned)
          reset_realtime_tick(info[:topic])
          realtime_payload << build_task_payload(info, current_time, :realtime, reason: 'interval_start')
          mark_realtime_tick(info[:topic], current_time)
        end

        if realtime_tick_due?(info[:topic], current_time, info[:interval_minutes])
          realtime_payload << build_task_payload(info, current_time, :realtime)
        end
      end

      tasks = []
      tasks << create_broadcast_task('kline_batch', { batch: realtime_payload }) unless realtime_payload.empty?
      tasks << create_broadcast_task('kline_batch', { batch: aligned_payload }) unless aligned_payload.empty?

      log_scheduling_stats('KlineScheduling', tasks.size)
      tasks
    end
    
    private
    
    def build_topic_info(topic)
      parsed = ::Realtime::TopicParser.parse_topic(topic)
      return nil unless parsed && parsed[:topic_type] == 'KLINE'

      interval = parsed[:interval].to_i
      return nil if interval <= 0

      {
        topic: topic,
        market_id: parsed[:market_id],
        interval_minutes: interval
      }
    end

    def build_task_payload(info, timestamp, kind, reason: nil)
      {
        topic: info[:topic],
        market_id: info[:market_id],
        interval_minutes: info[:interval_minutes],
        timestamp: timestamp,
        is_realtime: kind == :realtime,
        tick_reason: reason || (kind == :realtime ? 'heartbeat' : 'aligned_final')
      }
    end

    def aligned_window_end(current_time, interval_minutes)
      interval_seconds = interval_minutes * 60
      (current_time / interval_seconds) * interval_seconds
    end

    def realtime_tick_due?(topic, current_time, interval_minutes)
      return false unless within_active_window?(topic, current_time, interval_minutes)

      key = last_realtime_tick_key(topic)
      last_tick = Sidekiq.redis { |conn| conn.get(key) }&.to_i

      if last_tick.nil? || current_time - last_tick >= REALTIME_TICK_INTERVAL
        mark_realtime_tick(topic, current_time)
        true
      else
        false
      end
    end

    def within_active_window?(topic, current_time, interval_minutes)
      next_aligned_val = Sidekiq.redis { |conn| conn.get("next_aligned_ts:#{topic}") }
      return false if next_aligned_val.nil?

      next_aligned_ts = next_aligned_val.to_i
      last_aligned_ts = next_aligned_ts - interval_minutes * 60

      current_time > last_aligned_ts && current_time <= next_aligned_ts
    end

    def reset_realtime_tick(topic)
      Sidekiq.redis { |conn| conn.del(last_realtime_tick_key(topic)) }
    end

    def last_realtime_tick_key(topic)
      "last_realtime_tick:#{topic}"
    end

    def mark_realtime_tick(topic, timestamp)
      Sidekiq.redis { |conn| conn.set(last_realtime_tick_key(topic), timestamp) }
    end
  end
end
