# frozen_string_literal: true

module RuntimeCache
  # 运行时市场数据缓存
  # 统一管理市场数据在 Redis 中的存储和读取
  class MarketDataStore
    class << self
      # 更新市场摘要数据
      # @param market_id [Integer] 市场ID
      # @param data [Hash] 市场数据
      # @param ttl [Integer] 过期时间（秒）
      def update_market_summary(market_id, data, ttl: nil)
        key = Keyspace.market_key(market_id)
        ttl ||= Keyspace.default_ttl_for_key(key)
        
        Redis.current.hset(key, data)
        Redis.current.expire(key, ttl)
        
        Rails.logger.debug "[RuntimeCache] Updated market summary for #{market_id}"
      end
      
      # 批量获取市场摘要数据
      # @param market_ids [Array<Integer>] 市场ID数组
      # @return [Hash] { market_id => data }
      def batch_get_market_summaries(market_ids)
        keys = Keyspace.batch_market_keys(market_ids)
        
        Redis.current.pipelined do |pipeline|
          keys.each { |key| pipeline.hgetall(key) }
        end.each_with_index.each_with_object({}) do |(data, index), result|
          market_id = market_ids[index]
          result[market_id] = data unless data.empty?
        end
      end
      
      # 批量更新市场摘要数据
      # @param market_data [Hash] { market_id => data }
      def batch_update_market_summaries(market_data)
        Redis.current.pipelined do |pipeline|
          market_data.each do |market_id, data|
            key = Keyspace.market_key(market_id)
            ttl = Keyspace.default_ttl_for_key(key)
            
            pipeline.hset(key, data)
            pipeline.expire(key, ttl)
          end
        end
        
        Rails.logger.debug "[RuntimeCache] Batch updated #{market_data.size} market summaries"
      end
      
      # 更新市场特定字段
      # @param market_id [Integer] 市场ID
      # @param field [String] 字段名
      # @param value [String] 字段值
      def update_market_field(market_id, field, value)
        key = Keyspace.market_key(market_id)
        Redis.current.hset(key, field, value)
        
        # 重新设置过期时间
        ttl = Keyspace.default_ttl_for_key(key)
        Redis.current.expire(key, ttl)
      end
      
      # 获取市场特定字段
      # @param market_id [Integer] 市场ID
      # @param field [String] 字段名
      # @return [String] 字段值
      def get_market_field(market_id, field)
        key = Keyspace.market_key(market_id)
        Redis.current.hget(key, field)
      end
      
      # 增加市场字段值（用于计数器）
      # @param market_id [Integer] 市场ID
      # @param field [String] 字段名
      # @param increment [Integer] 增量
      # @return [Integer] 新值
      def increment_market_field(market_id, field, increment = 1)
        key = Keyspace.market_key(market_id)
        new_value = Redis.current.hincrbyfloat(key, field, increment)
        
        # 重新设置过期时间
        ttl = Keyspace.default_ttl_for_key(key)
        Redis.current.expire(key, ttl)
        
        new_value
      end
      
      # 设置订阅计数
      # @param topic [String] 主题
      # @param count [Integer] 订阅数量
      def set_subscription_count(topic, count)
        key = Keyspace.sub_count_key(topic)
        
        if count > 0
          Redis.current.set(key, count)
          ttl = Keyspace.default_ttl_for_key(key)
          Redis.current.expire(key, ttl)
        else
          Redis.current.del(key)
        end
      end
      
      # 获取订阅计数
      # @param topic [String] 主题
      # @return [Integer] 订阅数量
      def get_subscription_count(topic)
        key = Keyspace.sub_count_key(topic)
        Redis.current.get(key).to_i
      end
      
      # 获取所有活跃的订阅
      # @return [Hash] { topic => count }
      def get_active_subscriptions
        Keyspace.active_subscription_keys.each_with_object({}) do |key, result|
          topic = Keyspace.parse_topic_from_sub_key(key)
          count = Redis.current.get(key).to_i
          result[topic] = count if count > 0
        end
      end
      
      # 设置下次对齐时间
      # @param topic [String] 主题
      # @param timestamp [Integer] 时间戳
      def set_next_aligned_time(topic, timestamp)
        key = Keyspace.next_aligned_key(topic)
        Redis.current.set(key, timestamp)
        
        # 对齐时间键不设置过期时间，直到任务完成
      end
      
      # 获取下次对齐时间
      # @param topic [String] 主题
      # @return [Integer] 时间戳
      def get_next_aligned_time(topic)
        key = Keyspace.next_aligned_key(topic)
        Redis.current.get(key)&.to_i
      end
      
      # 删除下次对齐时间
      # @param topic [String] 主题
      def delete_next_aligned_time(topic)
        key = Keyspace.next_aligned_key(topic)
        Redis.current.del(key)
      end
      
      # 存储K线数据
      # @param market_id [Integer] 市场ID
      # @param interval [Integer] 时间间隔
      # @param kline_data [Array] K线数据
      def store_kline(market_id, interval, kline_data)
        key = Keyspace.kline_key(market_id, interval)
        ttl = Keyspace.default_ttl_for_key(key)
        
        Redis.current.set(key, kline_data.to_json)
        Redis.current.expire(key, ttl)
      end
      
      # 获取K线数据
      # @param market_id [Integer] 市场ID
      # @param interval [Integer] 时间间隔
      # @return [Array] K线数据
      def get_kline(market_id, interval)
        key = Keyspace.kline_key(market_id, interval)
        data = Redis.current.get(key)
        
        return nil unless data
        
        JSON.parse(data)
      rescue JSON::ParserError
        nil
      end
      
      # 存储成交数据
      # @param market_id [Integer] 市场ID
      # @param trades [Array] 成交数据
      def store_trades(market_id, trades)
        key = Keyspace.trade_key(market_id)
        ttl = Keyspace.default_ttl_for_key(key)
        
        Redis.current.set(key, trades.to_json)
        Redis.current.expire(key, ttl)
      end
      
      # 获取成交数据
      # @param market_id [Integer] 市场ID
      # @return [Array] 成交数据
      def get_trades(market_id)
        key = Keyspace.trade_key(market_id)
        data = Redis.current.get(key)
        
        return nil unless data
        
        JSON.parse(data)
      rescue JSON::ParserError
        nil
      end
      
      # 清理过期或无效的数据
      def cleanup_expired_data
        cleaned_count = 0
        
        # 清理过期的市场数据
        Keyspace.find_keys("#{Keyspace::MARKET_PREFIX}:*").each do |key|
          if Keyspace.key_ttl(key) == -2 # 键不存在
            Keyspace.delete_key(key)
            cleaned_count += 1
          end
        end
        
        Rails.logger.info "[RuntimeCache] Cleaned #{cleaned_count} expired keys"
        cleaned_count
      end
      
      # 获取存储统计信息
      def storage_stats
        Keyspace.key_stats.merge({
          total_keys: Keyspace.find_keys("*").size,
          active_subscriptions: get_active_subscriptions.size
        })
      end

      # ===== 市场摘要缓存方法 =====

      # 获取市场摘要（带缓存）
      # @param market_id [Integer] 市场ID
      # @param force_refresh [Boolean] 是否强制刷新
      # @return [Hash, nil] 市场摘要数据
      def get_market_summary(market_id, force_refresh: false)
        return nil if market_id.blank?

        unless force_refresh
          key = Keyspace.summary_key(market_id)
          cached = Redis.current.get(key)
          return JSON.parse(cached) if cached.present?
        end

        # 缓存未命中，生成新数据
        summary = MarketData::MarketSummaryService.new.call(market_id)
        store_market_summary(market_id, summary)

        summary
      end

      # 批量获取市场摘要
      # @param market_ids [Array<Integer>] 市场ID数组
      # @param force_refresh [Boolean] 是否强制刷新
      # @return [Hash] market_id => summary 的映射
      def get_market_summaries(market_ids, force_refresh: false)
        return {} if market_ids.blank?

        # 批量获取缓存
        cached_results = {}
        missing_ids = []

        unless force_refresh
          Redis.current.pipelined do |pipeline|
            market_ids.each do |id|
              pipeline.get(Keyspace.summary_key(id))
            end
          end.each_with_index do |cached, index|
            if cached.present?
              cached_results[market_ids[index]] = JSON.parse(cached)
            else
              missing_ids << market_ids[index]
            end
          end
        end

        # 缓存未命中的批量生成
        if missing_ids.present?
          new_summaries = MarketData::MarketSummaryService.new.batch_call(missing_ids)
          store_market_summaries(new_summaries)
          cached_results.merge!(new_summaries)
        end

        cached_results
      end

      # 存储单个市场摘要
      # @param market_id [Integer] 市场ID
      # @param data [Hash] 市场摘要数据
      def store_market_summary(market_id, data)
        key = Keyspace.summary_key(market_id)
        ttl = Keyspace.default_ttl_for_key(key)

        Redis.current.set(key, data.to_json, ex: ttl)
        Redis.current.zadd(Keyspace.summary_markets_key, summary_score(data), market_id)

        Rails.logger.debug "[RuntimeCache] Stored market summary for #{market_id} (ttl=#{ttl}s)"
      end

      # 批量存储市场摘要
      # @param summaries [Hash] market_id => summary 的映射
      def store_market_summaries(summaries)
        return if summaries.blank?

        Redis.current.pipelined do |pipeline|
          summaries.each do |market_id, data|
            key = Keyspace.summary_key(market_id)
            ttl = Keyspace.default_ttl_for_key(key)
            pipeline.set(key, data.to_json, ex: ttl)
            pipeline.zadd(Keyspace.summary_markets_key, summary_score(data), market_id)
          end
        end

        Rails.logger.debug "[RuntimeCache] Stored #{summaries.size} market summaries"
      end

      # 批量获取市场摘要（仅从缓存）
      # @param market_ids [Array<Integer>] 市场ID数组
      # @return [Hash] market_id => summary 的映射
      def get_market_summaries_cached(market_ids)
        return {} if market_ids.blank?

        cached_results = {}
        Redis.current.pipelined do |pipeline|
          market_ids.each do |id|
            pipeline.get(Keyspace.summary_key(id))
          end
        end.each_with_index do |cached, index|
          next unless cached.present?

          cached_results[market_ids[index]] = JSON.parse(cached)
        end

        cached_results
      end

      def summary_score(data)
        ts = data[:updated_at] || data['updated_at']
        return Time.current.to_i if ts.blank?

        Time.iso8601(ts).to_i
      rescue ArgumentError
        Time.current.to_i
      end

      # 使市场摘要缓存失效（设置 dirty 标记）
      # @param market_id [Integer] 市场ID
      def invalidate_market_summary(market_id)
        MarketData::MarketSummaryStore.mark_dirty(market_id)
        Rails.logger.debug "[RuntimeCache] Marked market summary as dirty in PG (market_id=#{market_id})"
      end

      # 批量使市场摘要缓存失效
      # @param market_ids [Array<Integer>] 市场ID数组
      def invalidate_market_summaries(market_ids)
        return if market_ids.blank?

        market_ids.each { |market_id| MarketData::MarketSummaryStore.mark_dirty(market_id) }
        Rails.logger.debug "[RuntimeCache] Marked #{market_ids.size} market summaries as dirty in PG"
      end

      # 获取所有 dirty 的市场ID
      # @return [Array<Integer>] 市场ID数组
      def dirty_market_ids
        Trading::MarketSummary.where(dirty: true).pluck(:market_id).map(&:to_i)
      end
    end
  end
end
