# frozen_string_literal: true

module Jobs
  module MarketData
    module Generation
      class KlineJob
        include Sidekiq::Job

        sidekiq_options queue: :scheduler, retry: 2

    # K线周期定义（分钟）
        INTERVALS_IN_MINUTES = [30, 60, 360, 720, 1440, 10080].freeze
    # 分别对应: 30分钟, 1小时, 6小时, 12小时, 1天, 7天

    # @param target_market_ids [Array, nil] 指定市场ID列表（切片模式），nil表示分发模式
        def perform(target_market_ids = nil)
      # 切片模式：直接执行指定市场
      if target_market_ids.present?
        market_ids = Array(target_market_ids).flatten.compact.map(&:to_i)
        Rails.logger.info "[MarketData::Generation::KlineJob] 切片模式: 处理 #{market_ids.size} 个市场"
        execute_for_markets(market_ids)
        return
      end

      # 分发模式：Leader分发到切片队列
      begin
        unless Sidekiq::Election::Service.leader?
          Rails.logger.debug "[MarketData::Generation::KlineJob] 非Leader实例，跳过分发"
          return
        end
      rescue => e
        Rails.logger.error "[MarketData::Generation::KlineJob] 选举服务异常: #{e.message}，跳过本次分发"
        return
      end

      Rails.logger.info "[MarketData::Generation::KlineJob] 分发模式 (Leader): 开始分发K线生成任务"

      # 初始化切片分发器
      dispatcher = Sidekiq::Sharding::Dispatcher.new('kline_generate_')
      market_ids = Trading::Market.pluck(:market_id)

      Rails.logger.info "[MarketData::Generation::KlineJob] 📊 分发 #{market_ids.size} 个市场到 #{dispatcher.active_instance_count} 个实例"

      # 批量分发到切片队列
      dispatcher.dispatch_batch(self.class, market_ids)
    end

        private

        def execute_for_markets(market_ids)
      end_time = Time.now.to_i

      market_ids.each do |market_id|
        INTERVALS_IN_MINUTES.each do |interval_minute|
          step_seconds = interval_minute * 60

          begin
            persister = MarketData::KlinePersister.new(market_id: market_id, interval: step_seconds)
            inserted_count = persister.complete_kline_data(end_time: end_time)

            Rails.logger.info(
              "[MarketData::Generation::KlineJob] market=#{market_id} " \
                "interval=#{interval_minute}min => 新增K线: #{inserted_count}"
            )
          rescue => e
            Rails.logger.error(
              "[MarketData::Generation::KlineJob] 生成K线出错: market=#{market_id}, interval=#{interval_minute}, error=#{e.message}"
            )
          end
        end
      end
        end
      end
    end
  end
end
