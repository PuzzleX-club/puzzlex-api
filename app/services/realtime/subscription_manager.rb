# frozen_string_literal: true

module Realtime
  # WebSocket 订阅管理服务
  # 使用 Redis Set 管理订阅关系，避免计数器负数问题
  class SubscriptionManager
    attr_reader :connection_id

    def initialize(connection_id = nil)
      @connection_id = connection_id
      @redis = Redis.current
      @logger = Rails.logger
    end

    def add_connection(connection_id, meta = {})
      @connection_id = connection_id

      meta_data = {
        created_at: Time.now.to_i,
        last_seen: Time.now.to_i
      }.merge(meta.compact)

      @redis.hset("connection:#{connection_id}:meta", meta_data)
      @redis.sadd("active_connections", connection_id)

      if meta[:user_id]
        @redis.sadd("user:#{meta[:user_id]}:connections", connection_id)
        @redis.sadd("active_users", meta[:user_id])
      end

      @logger.info "[Realtime::SubscriptionManager] 添加连接 #{connection_id}, user: #{meta[:user_id]}"
      connection_id
    end

    def add_subscription(connection_id, topics)
      return 0 if topics.blank?

      topics = Array(topics)
      added_count = 0

      topics.each do |topic|
        if @redis.sadd("topic:#{topic}:subscribers", connection_id) == 1
          added_count += 1
          @logger.info "[Realtime::SubscriptionManager] #{connection_id} 订阅 #{topic}"
        else
          @logger.debug "[Realtime::SubscriptionManager] #{connection_id} 已订阅 #{topic}，跳过重复订阅"
        end

        @redis.sadd("connection:#{connection_id}:topics", topic)
      end

      update_last_seen(connection_id)

      @logger.info "[Realtime::SubscriptionManager] #{connection_id} 新增 #{added_count}/#{topics.size} 个订阅"
      added_count
    end

    def remove_subscription(connection_id, topics)
      return 0 if topics.blank?

      topics = Array(topics)
      removed_count = 0

      topics.each do |topic|
        if @redis.srem("topic:#{topic}:subscribers", connection_id) == 1
          removed_count += 1
          @logger.info "[Realtime::SubscriptionManager] #{connection_id} 取消订阅 #{topic}"
        else
          @logger.debug "[Realtime::SubscriptionManager] #{connection_id} 未订阅 #{topic}，跳过虚空取消"
        end

        @redis.srem("connection:#{connection_id}:topics", topic)
      end

      update_last_seen(connection_id)

      @logger.info "[Realtime::SubscriptionManager] #{connection_id} 移除 #{removed_count}/#{topics.size} 个订阅"
      removed_count
    end

    def update_subscription(connection_id, new_topics)
      old_topics = get_connection_topics(connection_id)
      new_topics = Array(new_topics)

      to_remove = old_topics - new_topics
      to_add = new_topics - old_topics

      remove_subscription(connection_id, to_remove) if to_remove.any?
      add_subscription(connection_id, to_add) if to_add.any?

      @logger.info "[Realtime::SubscriptionManager] #{connection_id} 订阅更新完成: +#{to_add.size}/-#{to_remove.size}"
    end

    def remove_connection(connection_id)
      topics = get_connection_topics(connection_id)

      topics.each do |topic|
        @redis.srem("topic:#{topic}:subscribers", connection_id)
      end

      user_id = @redis.hget("connection:#{connection_id}:meta", "user_id")
      if user_id
        @redis.srem("user:#{user_id}:connections", connection_id)

        if @redis.scard("user:#{user_id}:connections") == 0
          @redis.srem("active_users", user_id)
          @logger.info "[Realtime::SubscriptionManager] 用户 #{user_id} 已完全离线"
        end
      end

      @redis.del("connection:#{connection_id}:topics")
      @redis.del("connection:#{connection_id}:meta")
      @redis.srem("active_connections", connection_id)

      @logger.info "[Realtime::SubscriptionManager] 移除连接 #{connection_id}，清理 #{topics.size} 个订阅"
    end

    def get_connection_topics(connection_id)
      @redis.smembers("connection:#{connection_id}:topics")
    end

    def get_topic_subscribers(topic)
      @redis.smembers("topic:#{topic}:subscribers")
    end

    def get_topic_subscriber_count(topic)
      @redis.scard("topic:#{topic}:subscribers")
    end

    def self.has_subscribers?(topic)
      redis = Redis.current
      new_count = redis.scard("topic:#{topic}:subscribers")
      old_count = redis.get("sub_count:#{topic}").to_i
      (new_count > 0) || (old_count > 0)
    end

    def self.get_active_topics(pattern = "*")
      redis = Redis.current
      keys = redis.keys("topic:#{pattern}:subscribers")

      active_topics = keys.select do |key|
        redis.scard(key) > 0
      end.map do |key|
        key.sub("topic:", "").sub(":subscribers", "")
      end

      Rails.logger.debug "[Realtime::SubscriptionManager] 活跃主题: #{active_topics.size} 个"
      active_topics
    end

    def connection_alive?(connection_id)
      @redis.sismember("active_connections", connection_id)
    end

    def update_last_seen(connection_id)
      @redis.hset("connection:#{connection_id}:meta", "last_seen", Time.now.to_i)
    end

    def self.stats
      redis = Redis.current
      {
        active_connections: redis.scard("active_connections"),
        active_users: redis.scard("active_users"),
        active_topics: redis.keys("topic:*:subscribers").size,
        total_subscriptions: calculate_total_subscriptions
      }
    end

    def self.cleanup_stale_connections(timeout_minutes = 30)
      redis = Redis.current
      now = Time.now.to_i
      timeout = timeout_minutes * 60
      cleaned_count = 0

      redis.smembers("active_connections").each do |conn_id|
        last_seen = redis.hget("connection:#{conn_id}:meta", "last_seen").to_i

        if (now - last_seen) > timeout
          new(conn_id).remove_connection(conn_id)
          cleaned_count += 1
          Rails.logger.info "[Realtime::SubscriptionManager] 清理过期连接: #{conn_id}"
        end
      end

      Rails.logger.info "[Realtime::SubscriptionManager] 清理了 #{cleaned_count} 个过期连接"
      cleaned_count
    end

    private

    def self.calculate_total_subscriptions
      redis = Redis.current
      redis.keys("topic:*:subscribers").sum do |key|
        redis.scard(key)
      end
    end
  end
end
