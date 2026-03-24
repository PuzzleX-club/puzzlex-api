# frozen_string_literal: true

# Global external service stubs for ALL specs.
#
# Problem: 43 out of 82 spec files timeout because ActiveRecord model callbacks
# (Order, OrderFill, Market) try to connect to real Redis/blockchain services.
#
# Solution: Stub Redis.current, ActionCable.server.broadcast, Sidekiq.redis,
# and key service classes globally so NO spec needs manual stubs just to avoid
# connection timeouts.
#
# Override: Any spec that needs more specific behavior can re-stub on top of
# these defaults - RSpec allows overriding stubs within nested contexts.
# Specs tagged with `redis: :real` will skip these stubs (for integration tests
# that need a live Redis).

RSpec.configure do |config|
  config.before(:each) do |example|
    # Skip global stubs for specs tagged with `redis: :real`
    next if example.metadata[:redis] == :real

    # -------------------------------------------------------
    # 1. Stub Redis.current with a comprehensive mock
    # -------------------------------------------------------
    mock_redis = double('MockRedis')

    # String commands
    allow(mock_redis).to receive(:get).and_return(nil)
    allow(mock_redis).to receive(:set).and_return(true)
    allow(mock_redis).to receive(:setex).and_return(true)
    allow(mock_redis).to receive(:setnx).and_return(true)
    allow(mock_redis).to receive(:del).and_return(true)
    allow(mock_redis).to receive(:exists).and_return(0)
    allow(mock_redis).to receive(:exists?).and_return(false)
    allow(mock_redis).to receive(:incr).and_return(1)
    allow(mock_redis).to receive(:decr).and_return(0)
    allow(mock_redis).to receive(:expire).and_return(true)
    allow(mock_redis).to receive(:ttl).and_return(-1)
    allow(mock_redis).to receive(:keys).and_return([])
    allow(mock_redis).to receive(:type).and_return("none")
    allow(mock_redis).to receive(:mget).and_return([])
    allow(mock_redis).to receive(:mset).and_return(true)
    allow(mock_redis).to receive(:getset).and_return(nil)
    allow(mock_redis).to receive(:append).and_return(0)

    # Hash commands
    allow(mock_redis).to receive(:hset).and_return(true)
    allow(mock_redis).to receive(:hget).and_return(nil)
    allow(mock_redis).to receive(:hdel).and_return(true)
    allow(mock_redis).to receive(:hgetall).and_return({})
    allow(mock_redis).to receive(:hmset).and_return(true)
    allow(mock_redis).to receive(:mapped_hmset).and_return(true)
    allow(mock_redis).to receive(:hincrby).and_return(1)
    allow(mock_redis).to receive(:hexists).and_return(false)
    allow(mock_redis).to receive(:hkeys).and_return([])
    allow(mock_redis).to receive(:hvals).and_return([])
    allow(mock_redis).to receive(:hlen).and_return(0)

    # Set commands
    allow(mock_redis).to receive(:sadd).and_return(true)
    allow(mock_redis).to receive(:srem).and_return(true)
    allow(mock_redis).to receive(:smembers).and_return([])
    allow(mock_redis).to receive(:sismember).and_return(false)
    allow(mock_redis).to receive(:scard).and_return(0)
    allow(mock_redis).to receive(:spop).and_return(nil)
    allow(mock_redis).to receive(:srandmember).and_return(nil)

    # Sorted set commands
    allow(mock_redis).to receive(:zadd).and_return(true)
    allow(mock_redis).to receive(:zrem).and_return(true)
    allow(mock_redis).to receive(:zrange).and_return([])
    allow(mock_redis).to receive(:zrangebyscore).and_return([])
    allow(mock_redis).to receive(:zrevrange).and_return([])
    allow(mock_redis).to receive(:zrevrangebyscore).and_return([])
    allow(mock_redis).to receive(:zcard).and_return(0)
    allow(mock_redis).to receive(:zscore).and_return(nil)
    allow(mock_redis).to receive(:zrank).and_return(nil)
    allow(mock_redis).to receive(:zincrby).and_return(0.0)

    # List commands
    allow(mock_redis).to receive(:lpush).and_return(1)
    allow(mock_redis).to receive(:rpush).and_return(1)
    allow(mock_redis).to receive(:lpop).and_return(nil)
    allow(mock_redis).to receive(:rpop).and_return(nil)
    allow(mock_redis).to receive(:lrange).and_return([])
    allow(mock_redis).to receive(:llen).and_return(0)
    allow(mock_redis).to receive(:blpop).and_return(nil)
    allow(mock_redis).to receive(:brpop).and_return(nil)
    allow(mock_redis).to receive(:lrem).and_return(0)

    # Pub/Sub
    allow(mock_redis).to receive(:publish).and_return(0)

    # Transaction/Pipeline
    allow(mock_redis).to receive(:multi).and_yield(mock_redis).and_return([])
    allow(mock_redis).to receive(:exec).and_return([])
    allow(mock_redis).to receive(:pipelined).and_yield(mock_redis).and_return([])
    allow(mock_redis).to receive(:watch).and_return("OK")
    allow(mock_redis).to receive(:unwatch).and_return("OK")

    # Scripting
    allow(mock_redis).to receive(:eval).and_return(nil)
    allow(mock_redis).to receive(:evalsha).and_return(nil)

    # Connection
    allow(mock_redis).to receive(:ping).and_return("PONG")
    allow(mock_redis).to receive(:connected?).and_return(true)
    allow(mock_redis).to receive(:close).and_return(nil)
    allow(mock_redis).to receive(:disconnect!).and_return(nil)
    allow(mock_redis).to receive(:info).and_return({})
    allow(mock_redis).to receive(:select).and_return("OK")

    # Scan
    allow(mock_redis).to receive(:scan).and_return(["0", []])
    allow(mock_redis).to receive(:scan_each).and_return([].each)
    allow(mock_redis).to receive(:hscan_each).and_return([].each)
    allow(mock_redis).to receive(:sscan_each).and_return([].each)
    allow(mock_redis).to receive(:zscan_each).and_return([].each)

    allow(Redis).to receive(:current).and_return(mock_redis)
    allow(Redis).to receive(:new).and_return(mock_redis)

    # -------------------------------------------------------
    # 2. Stub Sidekiq.redis to yield the same mock
    # -------------------------------------------------------
    if defined?(Sidekiq)
      allow(Sidekiq).to receive(:redis).and_yield(mock_redis)
    end

    # -------------------------------------------------------
    # 3. Stub ActionCable.server.broadcast as a no-op
    # -------------------------------------------------------
    if defined?(ActionCable)
      allow(ActionCable.server).to receive(:broadcast).and_return(true)
    end

    # -------------------------------------------------------
    # 4. Stub Realtime::SubscriptionGuard (uses Redis.keys)
    # -------------------------------------------------------
    if defined?(Realtime::SubscriptionGuard)
      allow(Realtime::SubscriptionGuard).to receive(:depth_limits_for_market).and_return([])
      allow(Realtime::SubscriptionGuard).to receive(:has_subscribers?).and_return(false)
    end

    # -------------------------------------------------------
    # 5. Stub SubscriptionManager class methods (uses Redis)
    # -------------------------------------------------------
    if defined?(Realtime::SubscriptionManager)
      allow(Realtime::SubscriptionManager).to receive(:has_subscribers?).and_return(false)
      allow(Realtime::SubscriptionManager).to receive(:get_active_topics).and_return([])
      allow(Realtime::SubscriptionManager).to receive(:stats).and_return({
        active_connections: 0,
        active_users: 0,
        active_topics: 0,
        total_subscriptions: 0
      })
      allow(Realtime::SubscriptionManager).to receive(:cleanup_stale_connections).and_return(0)
    end

    # -------------------------------------------------------
    # 6. Stub MarketData::FillEventRecorder.record!
    #    (called by OrderFill after_create callback)
    # -------------------------------------------------------
    if defined?(MarketData::FillEventRecorder)
      allow(MarketData::FillEventRecorder).to receive(:record!).and_return(nil)
    end

    # -------------------------------------------------------
    # 7. Stub MarketData::MarketSummaryStore.mark_dirty
    #    (called by Order after_commit callback - does DB upsert
    #     which can fail if MarketSummary table schema differs)
    # -------------------------------------------------------
    if defined?(MarketData::MarketSummaryStore)
      allow(MarketData::MarketSummaryStore).to receive(:mark_dirty).and_return(nil)
    end

    # -------------------------------------------------------
    # 8. Stub blockchain RPC clients if loaded
    # -------------------------------------------------------
    if defined?(Eth::Client)
      allow_any_instance_of(Eth::Client).to receive(:call).and_return('0x1')
      allow_any_instance_of(Eth::Client).to receive(:eth_get_balance).and_return(1_000_000)
      allow_any_instance_of(Eth::Client).to receive(:eth_block_number).and_return(12345678)
      allow_any_instance_of(Eth::Client).to receive(:eth_get_transaction_receipt).and_return({
        'status' => '0x1',
        'blockNumber' => '0xbc614e'
      })
    end
  end
end
