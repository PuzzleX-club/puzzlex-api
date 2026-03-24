# frozen_string_literal: true

module Jobs::Matching
  class Worker
    include Sidekiq::Worker

    sidekiq_options retry: 3, dead: false, unique: :until_and_while_executing, unique_expiration: 5

    def perform(market_id, trigger_source = 'scheduled')
      trace_id = SecureRandom.uuid
      Thread.current[:sidekiq_trace_id] = trace_id

      sched = Rails.configuration.x.match_scheduler
      start_time = Time.current
      total_matched = 0
      lock_acquired = false
      budget_exceeded = false

      Rails.logger.info "[Matching::Worker] start | trace=#{trace_id} | market=#{market_id} | trigger=#{trigger_source}"

      # Guard: lock TTL must exceed worker timeout to prevent unprotected execution
      effective_lock_ttl = [sched.lock_ttl_sec, sched.worker_timeout_sec + 5].max

      Timeout.timeout(sched.worker_timeout_sec) do
        with_redis_lock("match_lock:#{market_id}", effective_lock_ttl) do |acquired|
          lock_acquired = acquired
          next unless acquired

          # Clear dedup key after lock acquired; allows follow-up scheduling after this worker
          Sidekiq.redis { |conn| conn.del("match_followup:#{market_id}") }

          loop_start = Time.current
          round = 0

          loop do
            if Time.current - loop_start > sched.loop_budget_sec
              budget_exceeded = true
              break
            end

            round += 1
            matcher = Matching::Engine.new(market_id, trigger_source)

            if round == 1 && matcher.logger.respond_to?(:log_entry)
              log_entry = matcher.logger.log_entry
              log_entry&.update!(redis_data_stored: { trace_id: trace_id })
            end

            result = matcher.perform
            matched_count = result[:matched_count] || 0
            total_matched += matched_count

            break if matched_count == 0
          end
        end
      end

      # Post-lock: metrics + scheduling (outside lock hold time)
      if lock_acquired
        duration = Time.current - start_time
        record_matching_metrics(market_id, duration, total_matched)

        if budget_exceeded || total_matched > 0
          schedule_followup_if_idle(market_id, sched)
        else
          current_status = Sidekiq.redis { |conn| conn.hget("orderMatcher:#{market_id}", "status") }
          schedule_waiting_check(market_id, sched) if current_status == "waiting"
        end

        Rails.logger.info "[Matching::Worker] done | trace=#{trace_id} | #{(duration * 1000).round(2)}ms | matched=#{total_matched} | budget_exceeded=#{budget_exceeded}"
      end

    rescue Timeout::Error => e
      Rails.logger.error "[Matching::Worker] timeout | trace=#{trace_id} | #{e.message} | #{((Time.current - start_time) * 1000).round(2)}ms"
      raise

    rescue => e
      Rails.logger.error "[Matching::Worker] error | trace=#{trace_id} | #{e.class}: #{e.message}"
      Rails.logger.error "[Matching::Worker] #{e.backtrace&.first(3)&.join(' | ')}"
      raise

    ensure
      Thread.current[:sidekiq_trace_id] = nil
    end

    private

    # Distributed lock: SET NX + Lua CAS release
    def with_redis_lock(lock_key, timeout = 60)
      lock_value = SecureRandom.uuid
      lock_acquired = false

      begin
        lock_acquired = Sidekiq.redis { |conn| conn.set(lock_key, lock_value, nx: true, ex: timeout) }

        if lock_acquired
          yield(true)
        else
          Rails.logger.warn "[Matching::Worker::Lock] contention on #{lock_key}"
          yield(false)
        end
      ensure
        if lock_acquired
          lua_script = <<~LUA
            if redis.call("get", KEYS[1]) == ARGV[1] then
              return redis.call("del", KEYS[1])
            else
              return 0
            end
          LUA

          Sidekiq.redis { |conn| conn.eval(lua_script, 1, lock_key, lock_value) }
        end
      end
    end

    def record_matching_metrics(market_id, duration, total_matched)
      metrics = {
        event: 'order_matching_completed',
        market_id: market_id,
        duration_ms: (duration * 1000).round(2),
        matched_orders: total_matched,
        success: true,
        timestamp: Time.current.iso8601
      }

      Rails.logger.info "[Matching::Worker::Metrics] #{metrics.to_json}"
    end

    # Atomic dedup: SET NX + EX ensures at most one pending follow-up per market
    def schedule_followup_if_idle(market_id, sched)
      dedup_key = "match_followup:#{market_id}"

      scheduled = Sidekiq.redis do |conn|
        conn.set(dedup_key, "1", nx: true, ex: sched.dedup_ttl_sec)
      end

      if scheduled
        self.class.perform_in(sched.followup_delay_sec.seconds, market_id, 'followup')
        Rails.logger.info "[Matching::Worker::Schedule] #{market_id} follow-up in #{sched.followup_delay_sec}s"
      else
        Rails.logger.debug "[Matching::Worker::Schedule] #{market_id} follow-up already pending, skip"
      end
    rescue => e
      Rails.logger.error "[Matching::Worker::Schedule] #{market_id} follow-up schedule failed: #{e.message}"
    end

    # Waiting check with independent dedup key
    def schedule_waiting_check(market_id, sched)
      dedup_key = "match_waiting:#{market_id}"

      scheduled = Sidekiq.redis do |conn|
        conn.set(dedup_key, "1", nx: true, ex: sched.waiting_delay_sec)
      end

      if scheduled
        self.class.perform_in(sched.waiting_delay_sec.seconds, market_id, 'waiting_check')
        Rails.logger.debug "[Matching::Worker::Schedule] #{market_id} waiting check in #{sched.waiting_delay_sec}s"
      end
    rescue => e
      Rails.logger.error "[Matching::Worker::Schedule] #{market_id} waiting schedule failed: #{e.message}"
    end

    # Kept for backward compatibility; not called in normal flow.
    def sync_order_status_from_chain(result)
      return unless result.is_a?(Hash) && result[:matched_orders].present?

      order_hashes = []

      result[:matched_orders].each do |match_data|
        bid = match_data['bid']
        order_hashes << bid[2] if bid && bid[2]

        ask = match_data['ask']
        order_hashes.concat(ask[:current_orders]) if ask && ask[:current_orders]
      end

      order_hashes.uniq.each do |order_hash|
        Orders::OrderStatusUpdater.update_order_status(order_hash)
      rescue => e
        Rails.logger.error "[Matching::Worker] status sync failed: #{order_hash} - #{e.message}"
      end
    rescue => e
      Rails.logger.error "[Matching::Worker] batch status sync failed: #{e.message}"
    end

    def self.perform_sync(market_id, trigger_source = 'scheduled')
      new.perform(market_id, trigger_source)
    end
  end
end
