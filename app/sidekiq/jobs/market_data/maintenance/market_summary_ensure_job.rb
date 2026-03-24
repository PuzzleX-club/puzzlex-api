# frozen_string_literal: true

module Jobs
  module MarketData
  # 市场摘要补全 Worker
  # 每小时扫描 markets，确保 summary 记录存在并写入 Redis
    module Maintenance
      class MarketSummaryEnsureJob
        include Sidekiq::Worker
        sidekiq_options queue: :scheduler, retry: false

        DEFAULT_BATCH_SIZE = 200

    # @param target_market_ids [Array, nil] 指定市场ID列表（切片模式），nil表示分发模式
        def perform(target_market_ids = nil)
      # 切片模式：直接执行指定市场
      if target_market_ids.present?
        market_ids = Array(target_market_ids).flatten.compact.map(&:to_i)
        execute_for_markets(market_ids)
        return
      end

      # 分发模式：Leader分发到切片队列
      begin
        unless Sidekiq::Election::Service.leader?
          Rails.logger.debug "[MarketData::Maintenance::MarketSummaryEnsureJob] 非Leader实例，跳过分发"
          return
        end
      rescue => e
        Rails.logger.error "[MarketData::Maintenance::MarketSummaryEnsureJob] 选举服务异常: #{e.message}，跳过本次分发"
        return
      end

      market_ids = Trading::Market.pluck(:market_id)
      if market_ids.empty?
        Rails.logger.info "[MarketData::Maintenance::MarketSummaryEnsureJob] 无可补全市场"
        return
      end

      dispatcher = Sidekiq::Sharding::Dispatcher.new('market_summary_ensure_')
      if dispatcher.active_instance_count == 0
        Rails.logger.warn "[MarketData::Maintenance::MarketSummaryEnsureJob] 无活跃Worker实例，Leader兜底执行"
        execute_for_markets(market_ids)
        return
      end

      Rails.logger.info "[MarketData::Maintenance::MarketSummaryEnsureJob] 📊 分发 #{market_ids.size} 个市场到 #{dispatcher.active_instance_count} 个实例"
      dispatch_batches(dispatcher, market_ids)
    end

        private

        def execute_for_markets(market_ids)
      return if market_ids.empty?

      Rails.logger.info "[MarketData::Maintenance::MarketSummaryEnsureJob] 开始补全 (count=#{market_ids.size})"

      market_ids.each_slice(DEFAULT_BATCH_SIZE) do |batch|
        summaries = MarketData::MarketSummaryService.new.batch_call(batch)
        MarketData::MarketSummaryStore.upsert_summaries(summaries.values)
        RuntimeCache::MarketDataStore.store_market_summaries(summaries)
      end

      Rails.logger.info "[MarketData::Maintenance::MarketSummaryEnsureJob] 补全完成 (count=#{market_ids.size})"
    end

        def dispatch_batches(dispatcher, market_ids)
      queue_mapping = dispatcher.market_queue_mapping(market_ids)
      grouped = queue_mapping.each_with_object(Hash.new { |h, k| h[k] = [] }) do |(market_id, queue), result|
        result[queue] << market_id
      end

      grouped.each do |queue, ids|
        self.class.set(queue: queue).perform_async(ids)
      end
        end
      end
    end
  end
end
