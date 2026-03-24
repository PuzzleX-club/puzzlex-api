# frozen_string_literal: true

module RuntimeCache
  # 运行时缓存键空间
  # 统一管理 Redis 运行时缓存键的命名和过期时间
  class Keyspace
    # 市场数据相关键
    MARKET_PREFIX = "market"
    SUB_COUNT_PREFIX = "sub_count"
    KLINE_PREFIX = "kline"
    TRADE_PREFIX = "trade"
    DEPTH_PREFIX = "depth"
    NEXT_ALIGNED_PREFIX = "next_aligned_ts"
    SUMMARY_PREFIX = "summary"
    SUMMARY_MARKETS_KEY = "summary_markets"

    # 默认过期时间（秒）
    DEFAULT_MARKET_TTL = 3600      # 1小时
    DEFAULT_KLINE_TTL = 86400      # 24小时
    DEFAULT_TRADE_TTL = 1800       # 30分钟
    DEFAULT_DEPTH_TTL = 300        # 5分钟
    DEFAULT_SUB_COUNT_TTL = 3600   # 1小时
    DEFAULT_NEXT_ALIGNED_TTL = 86400  # 24小时 - 时间对齐标记
    DEFAULT_INITIALIZATION_TTL = 86400 # 24小时 - 初始化标记
    DEFAULT_SUMMARY_TTL = 10       # 10秒 - 市场摘要缓存（高频更新）
    
    class << self
      # 市场数据键
      def market_key(market_id)
        "#{MARKET_PREFIX}:#{market_id}"
      end
      
      # 订阅数量键
      def sub_count_key(topic)
        "#{SUB_COUNT_PREFIX}:#{topic}"
      end
      
      # K线数据键
      def kline_key(market_id, interval)
        "#{KLINE_PREFIX}:#{market_id}:#{interval}"
      end
      
      # 成交数据键
      def trade_key(market_id)
        "#{TRADE_PREFIX}:#{market_id}"
      end
      
      # 深度数据键
      def depth_key(market_id, limit = 20)
        "#{DEPTH_PREFIX}:#{market_id}:#{limit}"
      end
      
      # 下次对齐时间键
      def next_aligned_key(topic)
        "#{NEXT_ALIGNED_PREFIX}:#{topic}"
      end
      
      # 预关闭价格缓存键
      def preclose_key(market_id, timestamp)
        "preclose:#{market_id}:#{timestamp}"
      end

      # 市场摘要缓存键
      def summary_key(market_id)
        "#{SUMMARY_PREFIX}:#{market_id}"
      end

      # 市场摘要 dirty 标记键（用于缓存失效）
      def summary_dirty_key(market_id)
        "summary_dirty:#{market_id}"
      end

      # 市场摘要列表索引（ZSET）
      def summary_markets_key
        SUMMARY_MARKETS_KEY
      end
      
      # 批量生成键
      def batch_market_keys(market_ids)
        market_ids.map { |id| market_key(id) }
      end
      
      # 根据模式查找键
      def find_keys(pattern)
        Redis.current.keys(pattern)
      end
      
      # 获取所有活跃的订阅键
      def active_subscription_keys
        find_keys("#{SUB_COUNT_PREFIX}:*").select do |key|
          Redis.current.get(key).to_i > 0
        end
      end
      
      # 从键中解析topic
      def parse_topic_from_sub_key(sub_key)
        sub_key.sub("#{SUB_COUNT_PREFIX}:", "")
      end
      
      # 从键中解析市场ID
      def parse_market_id_from_key(key)
        key.split(':')[1]&.to_i
      end
      
      # 键是否存在
      def key_exists?(key)
        Redis.current.exists(key) > 0
      end
      
      # 获取键的TTL
      def key_ttl(key)
        Redis.current.ttl(key)
      end
      
      # 设置键的过期时间
      def set_ttl(key, ttl)
        Redis.current.expire(key, ttl)
      end
      
      # 删除键
      def delete_key(key)
        Redis.current.del(key)
      end
      
      # 批量删除键
      def delete_keys(keys)
        return 0 if keys.empty?
        
        Redis.current.del(*keys)
      end
      
      # 删除符合模式的所有键
      def delete_keys_by_pattern(pattern)
        keys = find_keys(pattern)
        delete_keys(keys)
      end
      
      # 获取键的默认TTL
      def default_ttl_for_key(key)
        case key
        when /^#{MARKET_PREFIX}:/
          DEFAULT_MARKET_TTL
        when /^#{KLINE_PREFIX}:/
          DEFAULT_KLINE_TTL
        when /^#{TRADE_PREFIX}:/
          DEFAULT_TRADE_TTL
        when /^#{DEPTH_PREFIX}:/
          DEFAULT_DEPTH_TTL
        when /^#{SUB_COUNT_PREFIX}:/
          DEFAULT_SUB_COUNT_TTL
        when /^#{NEXT_ALIGNED_PREFIX}:/
          DEFAULT_NEXT_ALIGNED_TTL
        when /^initialization_done$/
          DEFAULT_INITIALIZATION_TTL
        when /^#{SUMMARY_PREFIX}:/
          DEFAULT_SUMMARY_TTL
        else
          3600 # 默认1小时
        end
      end
      
      # 键统计信息
      def key_stats
        stats = {}
        
        [MARKET_PREFIX, SUB_COUNT_PREFIX, KLINE_PREFIX, TRADE_PREFIX, DEPTH_PREFIX].each do |prefix|
          pattern = "#{prefix}:*"
          keys = find_keys(pattern)
          
          stats[prefix] = {
            count: keys.size,
            memory_usage: calculate_memory_usage(keys),
            expired_count: keys.count { |key| key_ttl(key) == -1 }
          }
        end
        
        stats
      end
      
      private
      
      # 计算内存使用量（近似）
      def calculate_memory_usage(keys)
        total_size = 0
        
        keys.each do |key|
          # 获取键的类型和大小
          key_type = Redis.current.type(key)
          
          case key_type
          when "string"
            total_size += Redis.current.strlen(key)
          when "hash"
            total_size += Redis.current.hlen(key) * 50 # 估算
          when "list"
            total_size += Redis.current.llen(key) * 50 # 估算
          when "set"
            total_size += Redis.current.scard(key) * 50 # 估算
          when "zset"
            total_size += Redis.current.zcard(key) * 50 # 估算
          end
        end
        
        total_size
      end
    end
  end
end
