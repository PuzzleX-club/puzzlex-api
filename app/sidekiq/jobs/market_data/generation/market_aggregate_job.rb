# frozen_string_literal: true

module Jobs
  module MarketData
    module Generation
      # 按市场批量聚合 24 小时窗口的 Trading::MarketIntradayStat
      class MarketAggregateJob
        include Sidekiq::Job

        sidekiq_options queue: :scheduler, retry: 2

        # @param target_market_ids [Array, nil] 指定市场ID列表（切片模式），nil表示分发模式
        def perform(target_market_ids = nil)
          if target_market_ids.present?
            market_ids = Array(target_market_ids).flatten.compact.map(&:to_i).uniq
            Rails.logger.info "[MarketData::Generation::MarketAggregateJob] 切片模式: 聚合 #{market_ids.size} 个市场"
            execute_for_markets(market_ids)
            return
          end

          begin
            unless Sidekiq::Election::Service.leader?
              Rails.logger.debug "[MarketData::Generation::MarketAggregateJob] 非Leader实例，跳过分发"
              return
            end
          rescue => e
            Rails.logger.error "[MarketData::Generation::MarketAggregateJob] 选举服务异常: #{e.message}，跳过本次分发"
            return
          end

          Rails.logger.info "[MarketData::Generation::MarketAggregateJob] 分发模式 (Leader): 开始分发聚合任务"
          dispatcher = Sidekiq::Sharding::Dispatcher.new('market_aggregate_')
          market_ids = Trading::Market.pluck(:market_id)
          Rails.logger.info "[MarketData::Generation::MarketAggregateJob] 📊 分发 #{market_ids.size} 个市场到 #{dispatcher.active_instance_count} 个实例"
          dispatcher.dispatch_batch(self.class, market_ids)
        end

        private

        def execute_for_markets(market_ids)
          return if market_ids.empty?

          market_ids.each do |market_id|
            MarketData::MarketIntradayAggregator.new(market_id).call
          rescue => e
            Rails.logger.error "[MarketData::Generation::MarketAggregateJob] 聚合失败 market=#{market_id}: #{e.message}"
            Sentry.capture_exception(e) if defined?(Sentry)
          end
        end
      end
    end
  end
end
