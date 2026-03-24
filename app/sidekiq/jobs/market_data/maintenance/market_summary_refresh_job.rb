# frozen_string_literal: true

module Jobs
  module MarketData
  # 市场摘要刷新 Worker
  # 定期检查 dirty 标记并刷新市场摘要缓存
    module Maintenance
      class MarketSummaryRefreshJob
        include Sidekiq::Worker
        sidekiq_options queue: :scheduler, retry: false

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
          Rails.logger.debug "[MarketData::Maintenance::MarketSummaryRefreshJob] 非Leader实例，跳过分发"
          return
        end
      rescue => e
        Rails.logger.error "[MarketData::Maintenance::MarketSummaryRefreshJob] 选举服务异常: #{e.message}，跳过本次分发"
        return
      end

      # 获取所有 dirty 的市场ID（PG）
      dirty_market_ids = Trading::MarketSummary.where(dirty: true).pluck(:market_id).map(&:to_i)

      if dirty_market_ids.empty?
        Rails.logger.debug "[MarketData::Maintenance::MarketSummaryRefreshJob] 没有 dirty 的市场需要刷新"
        return
      end

      dispatcher = Sidekiq::Sharding::Dispatcher.new('market_summary_refresh_')
      if dispatcher.active_instance_count == 0
        Rails.logger.warn "[MarketData::Maintenance::MarketSummaryRefreshJob] 无活跃Worker实例，Leader兜底执行"
        execute_for_markets(dirty_market_ids)
        return
      end

      Rails.logger.info "[MarketData::Maintenance::MarketSummaryRefreshJob] 📊 分发 #{dirty_market_ids.size} 个市场到 #{dispatcher.active_instance_count} 个实例"
      dispatch_batches(dispatcher, dirty_market_ids)
    end

        private

        def execute_for_markets(market_ids)
      if market_ids.empty?
        Rails.logger.debug "[MarketData::Maintenance::MarketSummaryRefreshJob] 没有 dirty 的市场需要刷新"
        return
      end

      Rails.logger.info "[MarketData::Maintenance::MarketSummaryRefreshJob] 开始刷新 #{market_ids.size} 个 dirty 市场"

      begin
        summaries = MarketData::MarketSummaryService.new.batch_call(market_ids)
        MarketData::MarketSummaryStore.upsert_summaries(summaries.values)
        RuntimeCache::MarketDataStore.store_market_summaries(summaries)
        Rails.logger.info "[MarketData::Maintenance::MarketSummaryRefreshJob] 完成刷新 (count=#{market_ids.size})"
      rescue => e
        Rails.logger.error "[MarketData::Maintenance::MarketSummaryRefreshJob] 刷新失败: #{e.message}"
        raise e
      end
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
