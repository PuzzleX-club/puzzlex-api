# frozen_string_literal: true

class Matching::State::ResultStore
  def initialize(market_id:, redis_key:, logger:, validator:)
    @market_id = market_id
    @redis_key = redis_key
    @logger = logger
    @validator = validator
  end

  def store_match_data_in_redis(match_data)
    Rails.logger.debug "[QUEUE] 开始将撮合数据入队到List队列"

    queue_manager = Matching::State::QueueManager.instance
    queue_data = {
      market_id: @market_id,
      match_data_version: match_data[:match_data_version] || 'v1',
      orders: match_data[:orders],
      fulfillments: match_data[:fulfillments],
      orders_hash: match_data[:orders_hash]
    }

    queue_data[:fills] = match_data[:fills] if match_data[:fills].present?

    if match_data[:criteriaResolvers].present?
      queue_data[:criteriaResolvers] = match_data[:criteriaResolvers]
      Rails.logger.info "[MatchEngine] 📦 将criteriaResolvers添加到队列数据: #{match_data[:criteriaResolvers].size} 个"
    end

    queue_depth = queue_manager.enqueue_match(@market_id, queue_data)

    Rails.logger.info "[QUEUE] ✅ 撮合数据已入队: #{match_data[:orders].size}个订单, 市场: #{@market_id}, 队列深度: #{queue_depth}"

    Sidekiq.redis do |redis|
      redis.multi do |txn|
        txn.hset(@redis_key, 'status', 'queued')
        txn.hset(@redis_key, 'match_data_version', match_data[:match_data_version] || 'v1')
        txn.hset(@redis_key, 'queued_at', Time.current.to_f.to_s)
        txn.hset(@redis_key, 'queue_depth', queue_depth.to_s)
      end
    end
  rescue => e
    Rails.logger.error "[QUEUE] ❌ 撮合数据入队失败: #{e.message}"
    fallback_to_hash_storage(match_data)
    raise
  end

  def fallback_to_hash_storage(match_data)
    Rails.logger.warn "[FALLBACK] 队列操作失败，降级使用Hash存储"

    Sidekiq.redis do |redis|
      redis.multi do |txn|
        txn.hset(@redis_key, 'status', 'matched')
        txn.hset(@redis_key, 'match_data_version', match_data[:match_data_version] || 'v1')
        txn.hset(@redis_key, 'orders', match_data[:orders].to_json)
        txn.hset(@redis_key, 'fulfillments', match_data[:fulfillments].to_json)
        txn.hset(@redis_key, 'orders_hash', match_data[:orders_hash].to_json)
        txn.hset(@redis_key, 'fills', match_data[:fills].to_json) if match_data[:fills].present?
        txn.hset(@redis_key, 'matched_at', Time.current.to_f.to_s)
      end
    end
  end

  def set_redis_status_to_waiting
    Rails.logger.debug "[REDIS_ATOMIC] 开始原子性设置等待状态"

    Sidekiq.redis do |redis|
      redis.multi do |txn|
        txn.hset(@redis_key, 'status', 'waiting')
        txn.hdel(@redis_key, 'orders')
        txn.hdel(@redis_key, 'fulfillments')
        txn.hdel(@redis_key, 'orders_hash')
        txn.hdel(@redis_key, 'fills')
        txn.hdel(@redis_key, 'match_data_version')
        txn.hdel(@redis_key, 'matched_at')
        txn.hdel(@redis_key, 'orders_count')
        txn.hset(@redis_key, 'waiting_since', Time.current.to_f.to_s)
      end
    end

    Rails.logger.info "[REDIS_ATOMIC] ✅ 原子性设置waiting状态完成, key=#{@redis_key}"
  rescue => e
    Rails.logger.error "[REDIS_ATOMIC] ❌ 原子性设置waiting状态失败: #{e.message}"
    raise
  end

  def handle_match_failure(order_hashes, error)
    Rails.logger.info "[MatchEngine] 处理撮合失败订单，设置为paused状态并入队恢复队列"

    order_hashes.each do |order_hash|
      order = Trading::Order.find_by(order_hash: order_hash)
      next unless order

      Orders::OrderStatusManager.new(order).set_offchain_status!(
        'paused',
        'matching_failed_pending_recovery'
      )
      Rails.logger.debug "[MatchEngine] 订单 #{order_hash} 设置为paused状态"
    end

    failed_queue_key = "match_failed_queue:#{@market_id}"
    recovery_data = {
      order_hashes: order_hashes,
      failed_at: Time.current.to_f,
      error: error.message,
      error_class: error.class.name,
      market_id: @market_id,
      source: 'match_engine',
      reason: 'matching_failed_pending_recovery'
    }

    Sidekiq.redis do |redis|
      redis.lpush(failed_queue_key, recovery_data.to_json)
      redis.expire(failed_queue_key, 3600)
    end

    Rails.logger.info "[MatchEngine] #{order_hashes.size} 个订单已入队失败恢复队列: #{failed_queue_key}"

    meta_key = "match_meta:#{@market_id}"
    Sidekiq.redis do |redis|
      redis.hincrby(meta_key, 'failed_count', 1)
      redis.hset(meta_key, 'last_error', error.message)
      redis.hset(meta_key, 'last_error_at', Time.current.to_f)
    end

    set_redis_status_to_waiting
  rescue => e
    Rails.logger.error "[MatchEngine] handle_match_failure失败: #{e.message}"
    @validator.restore_orders_after_failed_matching(order_hashes) rescue nil
  end
end
