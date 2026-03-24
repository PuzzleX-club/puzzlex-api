# frozen_string_literal: true

module Jobs
  module MarketData
  # 市场摘要 Redis 同步 Worker
  # 定期从 PG 读取 summary 写入 Redis + ZSET
    module Sync
      class MarketSummaryCacheJob
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
          Rails.logger.debug "[MarketData::Sync::MarketSummaryCacheJob] 非Leader实例，跳过分发"
          return
        end
      rescue => e
        Rails.logger.error "[MarketData::Sync::MarketSummaryCacheJob] 选举服务异常: #{e.message}，跳过本次分发"
        return
      end

      market_ids = Trading::MarketSummary.pluck(:market_id).map(&:to_i)
      if market_ids.empty?
        Rails.logger.info "[MarketData::Sync::MarketSummaryCacheJob] 无可同步市场"
        return
      end

      dispatcher = Sidekiq::Sharding::Dispatcher.new('market_summary_sync_')
      if dispatcher.active_instance_count == 0
        Rails.logger.warn "[MarketData::Sync::MarketSummaryCacheJob] 无活跃Worker实例，Leader兜底执行"
        execute_for_markets(market_ids)
        return
      end

      Rails.logger.info "[MarketData::Sync::MarketSummaryCacheJob] 📊 分发 #{market_ids.size} 个市场到 #{dispatcher.active_instance_count} 个实例"
      dispatch_batches(dispatcher, market_ids)
    end

        private

        def execute_for_markets(market_ids)
      return if market_ids.empty?

      Rails.logger.info "[MarketData::Sync::MarketSummaryCacheJob] 开始同步 (count=#{market_ids.size})"

      market_ids.each_slice(DEFAULT_BATCH_SIZE) do |batch|
        records = MarketData::MarketSummaryStore.fetch_summaries(batch)
        summaries = records.each_with_object({}) do |(market_id, record), result|
          serialized = MarketData::MarketSummaryStore.serialize(record)
          result[market_id.to_i] = serialized if serialized
        end

        RuntimeCache::MarketDataStore.store_market_summaries(summaries)
      end

      Rails.logger.info "[MarketData::Sync::MarketSummaryCacheJob] 同步完成 (count=#{market_ids.size})"
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
