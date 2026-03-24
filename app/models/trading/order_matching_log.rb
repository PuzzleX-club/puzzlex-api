module Trading
  class OrderMatchingLog < ApplicationRecord

    # 状态枚举
    enum status: {
      started: 'started',
      completed: 'completed',
      failed: 'failed',
      cancelled: 'cancelled'
    }, _prefix: :status

    # 移除严格的枚举限制，允许灵活的字符串

    # 算法类型枚举
    enum algorithm_used: {
      dp: 'dp',
      recursive: 'recursive',
      hybrid: 'hybrid',
      unknown: 'unknown'
    }, _prefix: :algorithm

    # 验证
    validates :market_id, presence: true
    validates :matching_session_id, presence: true, uniqueness: true
    validates :started_at, presence: true

    # JSON字段访问器
    store_accessor :input_bids_summary, :bid_price_range, :bid_total_qty, :bid_avg_price
    store_accessor :input_asks_summary, :ask_price_range, :ask_total_qty, :ask_avg_price
    store_accessor :filter_reasons, :insufficient_balance, :invalid_status, :in_matching, :expired
    store_accessor :matching_details, :groups, :total_matches, :algorithm_performance
    store_accessor :cache_stats, :merkle_cache_hits, :merkle_cache_misses, :cache_hit_rate
    store_accessor :performance_metrics, :memory_usage, :cpu_time, :db_queries
    store_accessor :redis_data_stored, :orders_count, :fulfillments_count, :data_size
    store_accessor :environment_info, :rails_env, :ruby_version, :redis_version

    # 作用域
    scope :for_market, ->(market_id) { where(market_id: market_id) }
    scope :recent, ->(days = 7) { where(started_at: days.days.ago..Time.current) }
    scope :successful, -> { where(status: 'completed') }
    scope :failed, -> { where(status: 'failed') }
    scope :by_trigger, ->(source) { where(trigger_source: source) }
    scope :by_algorithm, ->(algo) { where(algorithm_used: algo) }
    scope :with_matches, -> { where('matched_groups_count > 0') }
    scope :without_matches, -> { where(matched_groups_count: 0) }

    # 计算总耗时
    def calculate_duration!
      if started_at && completed_at
        self.total_duration_ms = ((completed_at - started_at) * 1000).round
      end

      if started_at && validation_completed_at
        self.validation_duration_ms = ((validation_completed_at - started_at) * 1000).round
      end

      if validation_completed_at && matching_completed_at
        self.matching_duration_ms = ((matching_completed_at - validation_completed_at) * 1000).round
      end
    end

    # 获取撮合效率
    def matching_efficiency
      return 0 if input_bids_count == 0 || input_asks_count == 0

      total_input = input_bids_count + input_asks_count
      return 0 if total_input == 0

      (matched_orders_count.to_f / total_input * 100).round(2)
    end

    # 获取过滤率
    def filter_rate
      return 0 if input_bids_count == 0 && input_asks_count == 0

      total_input = input_bids_count + input_asks_count
      total_filtered = filtered_bids_count + filtered_asks_count

      (total_filtered.to_f / total_input * 100).round(2)
    end

    # 是否成功撮合
    def successful_matching?
      status_completed? && matched_groups_count > 0
    end

    # 性能评级
    def performance_rating
      return 'unknown' unless total_duration_ms

      case total_duration_ms
      when 0..500
        'excellent'
      when 501..1000
        'good'
      when 1001..3000
        'acceptable'
      when 3001..10000
        'slow'
      else
        'very_slow'
      end
    end

    # 格式化持续时间
    def formatted_duration
      return 'N/A' unless total_duration_ms

      if total_duration_ms < 1000
        "#{total_duration_ms}ms"
      else
        "#{(total_duration_ms / 1000.0).round(2)}s"
      end
    end

    # 获取详细统计
    def detailed_stats
      {
        efficiency: matching_efficiency,
        filter_rate: filter_rate,
        performance: performance_rating,
        duration: formatted_duration,
        cache_efficiency: cache_stats&.dig('cache_hit_rate') || 0,
        orders_processed: input_bids_count + input_asks_count,
        matches_found: matched_groups_count
      }
    end

    # 类方法：统计分析
    class << self
      # 获取市场撮合统计
      def market_stats(market_id, days = 7)
        logs = for_market(market_id).recent(days)

        {
          total_sessions: logs.count,
          successful_sessions: logs.successful.count,
          success_rate: logs.count > 0 ? (logs.successful.count.to_f / logs.count * 100).round(2) : 0,
          avg_duration: logs.average(:total_duration_ms)&.round(2),
          total_matches: logs.sum(:matched_groups_count),
          avg_efficiency: logs.average(:matched_orders_count)&.round(2)
        }
      end

      # 获取算法性能对比
      def algorithm_performance(days = 7)
        recent(days).group(:algorithm_used)
                   .average(:total_duration_ms)
                   .transform_values { |v| v&.round(2) }
      end

      # 获取触发源统计
      def trigger_source_stats(days = 7)
        recent(days).group(:trigger_source).count
      end

      # 获取性能趋势
      def performance_trend(market_id = nil, days = 7)
        base_query = recent(days)
        base_query = base_query.for_market(market_id) if market_id

        base_query.group_by_day(:started_at)
                  .average(:total_duration_ms)
                  .transform_values { |v| v&.round(2) }
      end
    end
  end
end
