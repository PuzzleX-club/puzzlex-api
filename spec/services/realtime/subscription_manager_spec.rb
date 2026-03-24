require 'rails_helper'

RSpec.describe Realtime::SubscriptionManager, redis: :real do
  let(:connection_id) { 'conn_12345' }
  let(:user_id) { 42 }
  let(:topic) { 'market:201:depth' }
  let(:manager) { described_class.new(connection_id) }
  let(:redis) { Redis.current }

  before do
    # Clean up Redis before each test
    patterns = ["connection:*", "topic:*", "user:*", "active_*"]
    keys_to_clean = patterns.flat_map { |pattern| redis.keys(pattern) }
    keys_to_clean.each { |key| redis.del(key) }
  end

  after do
    # Clean up Redis after each test
    patterns = ["connection:*", "topic:*", "user:*", "active_*"]
    keys_to_clean = patterns.flat_map { |pattern| redis.keys(pattern) }
    keys_to_clean.each { |key| redis.del(key) }
  end

  describe '#initialize' do
    it 'initializes with default connection_id' do
      manager = described_class.new
      expect(manager.connection_id).to be_nil
    end

    it 'initializes with provided connection_id' do
      expect(manager.connection_id).to eq(connection_id)
    end

    it 'sets redis and logger' do
      expect(manager.instance_variable_get(:@redis)).to eq(redis)
      expect(manager.instance_variable_get(:@logger)).to eq(Rails.logger)
    end
  end

  describe '#add_connection' do
    it 'adds connection with metadata' do
      meta = { user_id: user_id, ip: '127.0.0.1' }
      result = manager.add_connection(connection_id, meta)

      expect(result).to eq(connection_id)
      expect(redis.sismember('active_connections', connection_id)).to be true
      expect(redis.sismember('active_users', user_id)).to be true
      expect(redis.sismember("user:#{user_id}:connections", connection_id)).to be true

      # Check metadata
      metadata = redis.hgetall("connection:#{connection_id}:meta")
      expect(metadata['user_id']).to eq(user_id.to_s)
      expect(metadata['ip']).to eq('127.0.0.1')
      expect(metadata['created_at']).to be_present
      expect(metadata['last_seen']).to be_present
    end

    it 'adds connection without user_id' do
      meta = { ip: '127.0.0.1' }
      manager.add_connection(connection_id, meta)

      expect(redis.sismember('active_connections', connection_id)).to be true
      expect(redis.smembers('active_users')).not_to include(user_id.to_s)
    end

    it 'handles nil values in metadata' do
      meta = { user_id: user_id, ip: nil }
      manager.add_connection(connection_id, meta)

      metadata = redis.hgetall("connection:#{connection_id}:meta")
      expect(metadata['user_id']).to eq(user_id.to_s)
      expect(metadata).not_to have_key('ip')
    end
  end

  describe '#add_subscription' do
    let(:topics) { ['market:201:depth', 'market:201:kline'] }

    before do
      manager.add_connection(connection_id, { user_id: user_id })
    end

    it 'adds multiple subscriptions' do
      result = manager.add_subscription(connection_id, topics)

      expect(result).to be > 0
      topics.each do |topic|
        expect(redis.sismember("topic:#{topic}:subscribers", connection_id)).to be true
        expect(redis.sismember("connection:#{connection_id}:topics", topic)).to be true
      end
    end

    it 'handles single subscription' do
      result = manager.add_subscription(connection_id, topic)

      expect(result).to eq(1)
      expect(redis.sismember("topic:#{topic}:subscribers", connection_id)).to be true
      expect(redis.sismember("connection:#{connection_id}:topics", topic)).to be true
    end

    it 'handles empty topics' do
      result = manager.add_subscription(connection_id, [])
      expect(result).to eq(0)

      result = manager.add_subscription(connection_id, nil)
      expect(result).to eq(0)
    end

    it 'does not add duplicate subscriptions' do
      # First addition
      result1 = manager.add_subscription(connection_id, topic)
      expect(result1).to eq(1)

      # Second addition (duplicate)
      result2 = manager.add_subscription(connection_id, topic)
      expect(result2).to eq(0)
    end

    it 'updates last_seen timestamp' do
      original_time = Time.now.to_i
      manager.add_subscription(connection_id, topic)

      last_seen = redis.hget("connection:#{connection_id}:meta", 'last_seen').to_i
      expect(last_seen).to be >= original_time
    end
  end

  describe '#remove_subscription' do
    let(:topics) { ['market:201:depth', 'market:201:kline'] }

    before do
      manager.add_connection(connection_id, { user_id: user_id })
      manager.add_subscription(connection_id, topics)
    end

    it 'removes multiple subscriptions' do
      result = manager.remove_subscription(connection_id, topics)

      expect(result).to eq(2)  # Removed 2 subscriptions
      topics.each do |topic|
        expect(redis.sismember("topic:#{topic}:subscribers", connection_id)).to be false
        expect(redis.sismember("connection:#{connection_id}:topics", topic)).to be false
      end
    end

    it 'handles single subscription' do
      result = manager.remove_subscription(connection_id, topic)

      expect(result).to eq(1)
      expect(redis.sismember("topic:#{topic}:subscribers", connection_id)).to be false
      expect(redis.sismember("connection:#{connection_id}:topics", topic)).to be false
    end

    it 'handles empty topics' do
      result = manager.remove_subscription(connection_id, [])
      expect(result).to eq(0)

      result = manager.remove_subscription(connection_id, nil)
      expect(result).to eq(0)
    end

    it 'handles non-existent subscriptions' do
      result = manager.remove_subscription(connection_id, 'nonexistent:topic')
      expect(result).to eq(0)
    end
  end

  describe '#update_subscription' do
    let(:old_topics) { ['market:201:depth', 'market:201:kline'] }
    let(:new_topics) { ['market:201:kline', 'market:201:trades'] }

    before do
      manager.add_connection(connection_id, { user_id: user_id })
      manager.add_subscription(connection_id, old_topics)
    end

    it 'replaces old subscriptions with new ones' do
      result = manager.update_subscription(connection_id, new_topics)

      expect(result).to be_truthy

      # Check old topics are removed (except those in new_topics)
      expect(redis.sismember("topic:market:201:depth:subscribers", connection_id)).to be false
      expect(redis.sismember("topic:market:201:kline:subscribers", connection_id)).to be true
      expect(redis.sismember("topic:market:201:trades:subscribers", connection_id)).to be true

      # Check connection's topic list
      connection_topics = redis.smembers("connection:#{connection_id}:topics")
      expect(connection_topics).to match_array(new_topics)
    end

    it 'handles empty new topics (clears all subscriptions)' do
      result = manager.update_subscription(connection_id, [])

      expect(result).to be_truthy
      expect(redis.smembers("connection:#{connection_id}:topics")).to be_empty
    end
  end

  describe '#remove_connection' do
    let(:topics) { ['market:201:depth', 'market:201:kline'] }

    before do
      manager.add_connection(connection_id, { user_id: user_id })
      manager.add_subscription(connection_id, topics)
    end

    it 'removes connection and all related data' do
      manager.remove_connection(connection_id)

      # Check connection is removed
      expect(redis.sismember('active_connections', connection_id)).to be false

      # Check user connection is removed
      expect(redis.sismember("user:#{user_id}:connections", connection_id)).to be false

      # Check all subscriptions are removed
      topics.each do |topic|
        expect(redis.sismember("topic:#{topic}:subscribers", connection_id)).to be false
      end

      # Check connection's topic list is removed
      expect(redis.exists?("connection:#{connection_id}:topics")).to be false

      # Check connection's metadata is removed
      expect(redis.exists?("connection:#{connection_id}:meta")).to be false
    end
  end

  describe '#get_connection_topics' do
    let(:topics) { ['market:201:depth', 'market:201:kline'] }

    before do
      manager.add_connection(connection_id)
      manager.add_subscription(connection_id, topics)
    end

    it 'returns connection topics' do
      result = manager.get_connection_topics(connection_id)
      expect(result).to match_array(topics)
    end

    it 'returns empty array for connection with no topics' do
      empty_connection_id = 'empty_conn'
      manager.add_connection(empty_connection_id)

      result = manager.get_connection_topics(empty_connection_id)
      expect(result).to be_empty
    end

    it 'returns empty array for non-existent connection' do
      result = manager.get_connection_topics('nonexistent')
      expect(result).to be_empty
    end
  end

  describe '#get_topic_subscribers' do
    let(:conn1) { 'conn_1' }
    let(:conn2) { 'conn_2' }

    before do
      manager.add_connection(conn1)
      manager.add_connection(conn2)
      manager.add_subscription(conn1, topic)
      manager.add_subscription(conn2, topic)
    end

    it 'returns all subscribers for a topic' do
      result = manager.get_topic_subscribers(topic)
      expect(result).to match_array([conn1, conn2])
    end

    it 'returns empty array for topic with no subscribers' do
      result = manager.get_topic_subscribers('nonexistent:topic')
      expect(result).to be_empty
    end
  end

  describe '#get_topic_subscriber_count' do
    let(:conn1) { 'conn_1' }
    let(:conn2) { 'conn_2' }

    before do
      manager.add_connection(conn1)
      manager.add_connection(conn2)
      manager.add_subscription(conn1, topic)
      manager.add_subscription(conn2, topic)
    end

    it 'returns subscriber count for topic' do
      result = manager.get_topic_subscriber_count(topic)
      expect(result).to eq(2)
    end

    it 'returns 0 for topic with no subscribers' do
      result = manager.get_topic_subscriber_count('nonexistent:topic')
      expect(result).to eq(0)
    end
  end

  describe '.has_subscribers?' do
    let(:conn1) { 'conn_1' }

    before do
      manager.add_connection(conn1)
    end

    it 'returns true when topic has subscribers' do
      manager.add_subscription(conn1, topic)
      expect(described_class.has_subscribers?(topic)).to be true
    end

    it 'returns false when topic has no subscribers' do
      expect(described_class.has_subscribers?('nonexistent:topic')).to be false
    end
  end

  describe '.get_active_topics' do
    let(:topics) { ['market:201:depth', 'market:201:kline', 'market:201:trades'] }

    before do
      manager.add_connection(connection_id)
      manager.add_subscription(connection_id, topics)
    end

    it 'returns all active topics' do
      result = described_class.get_active_topics
      expect(result).to include(*topics)
    end

    it 'filters topics by pattern' do
      result = described_class.get_active_topics('market:*:depth')
      expect(result).to include('market:201:depth')
      expect(result).not_to include('market:201:kline')
    end
  end

  describe '#connection_alive?' do
    before do
      manager.add_connection(connection_id)
    end

    it 'returns true for active connection' do
      expect(manager.connection_alive?(connection_id)).to be true
    end

    it 'returns false for non-existent connection' do
      expect(manager.connection_alive?('nonexistent')).to be false
    end
  end

  describe '#update_last_seen' do
    before do
      manager.add_connection(connection_id)
    end

    it 'updates last_seen timestamp' do
      # First create connection with initial timestamp
      manager.add_connection(connection_id)
      original_time = redis.hget("connection:#{connection_id}:meta", 'last_seen').to_i

      sleep 1  # Longer delay to ensure timestamp difference
      manager.update_last_seen(connection_id)

      last_seen = redis.hget("connection:#{connection_id}:meta", 'last_seen').to_i
      expect(last_seen).to be > original_time
    end
  end

  describe '.stats' do
    let(:conn1) { 'conn_1' }
    let(:conn2) { 'conn_2' }
    let(:user1_id) { 1 }
    let(:user2_id) { 2 }

    before do
      # Add connections and users
      manager.add_connection(conn1, { user_id: user1_id })
      manager.add_connection(conn2, { user_id: user2_id })

      # Add subscriptions
      manager.add_subscription(conn1, ['topic1', 'topic2'])
      manager.add_subscription(conn2, ['topic2', 'topic3'])
    end

    it 'returns statistics hash' do
      stats = described_class.stats

      expect(stats).to be_a(Hash)
      expect(stats[:active_connections]).to eq(2)
      expect(stats[:active_users]).to eq(2)
      expect(stats[:active_topics]).to eq(3)
      expect(stats[:total_subscriptions]).to eq(4)
    end
  end

  describe '.cleanup_stale_connections' do
    let(:old_connection) { 'old_conn' }
    let(:new_connection) { 'new_conn' }

    before do
      # Add old connection (simulate being stale)
      manager.add_connection(old_connection, { user_id: user_id })

      # Manually set old timestamp (1 hour ago)
      old_timestamp = (Time.now - 1.hour).to_i
      redis.hset("connection:#{old_connection}:meta", 'last_seen', old_timestamp)

      # Add new connection
      manager.add_connection(new_connection, { user_id: user_id + 1 })
    end

    it 'removes stale connections' do
      initial_count = redis.scard('active_connections')
      expect(initial_count).to eq(2)

      # Clean up connections older than 30 minutes
      described_class.cleanup_stale_connections(30)

      # Check old connection is removed
      expect(redis.sismember('active_connections', old_connection)).to be false
      expect(redis.sismember('active_connections', new_connection)).to be true

      final_count = redis.scard('active_connections')
      expect(final_count).to eq(1)
    end
  end

  describe 'Integration scenario' do
    it 'manages complete subscription lifecycle' do
      # Add connection
      manager.add_connection(connection_id, { user_id: user_id })
      expect(described_class.stats[:active_connections]).to eq(1)

      # Add subscriptions
      topics = ['market:201:depth', 'market:201:kline']
      manager.add_subscription(connection_id, topics)

      # Verify subscriptions
      expect(manager.get_topic_subscriber_count('market:201:depth')).to eq(1)
      expect(manager.get_topic_subscriber_count('market:201:kline')).to eq(1)
      expect(described_class.has_subscribers?('market:201:depth')).to be true

      # Update subscriptions
      new_topics = ['market:201:trades']
      manager.update_subscription(connection_id, new_topics)

      # Verify old subscriptions are removed
      expect(described_class.has_subscribers?('market:201:depth')).to be false
      expect(manager.get_topic_subscriber_count('market:201:trades')).to eq(1)

      # Remove connection
      manager.remove_connection(connection_id)
      expect(described_class.stats[:active_connections]).to eq(0)
      expect(described_class.has_subscribers?('market:201:trades')).to be false
    end
  end
end
