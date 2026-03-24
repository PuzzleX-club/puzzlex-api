# frozen_string_literal: true

module Jobs::Matching
  class OverMatchDispatchJob
    include Sidekiq::Job

    sidekiq_options queue: :scheduler, retry: 2

    MAX_PLAYERS_PER_RUN = 1000
    BATCH_SIZE = 200

    def perform
      begin
        unless Sidekiq::Election::Service.leader?
          Rails.logger.debug "[Matching::OverMatchDispatch] 非Leader实例，跳过调度"
          return
        end
      rescue => e
        Rails.logger.error "[Matching::OverMatchDispatch] 选举服务异常: #{e.message}，跳过本次调度"
        return
      end

      player_addresses = fetch_active_player_addresses
      if player_addresses.empty?
        Rails.logger.debug "[Matching::OverMatchDispatch] 无活跃玩家订单，跳过调度"
        return
      end

      dispatcher = Sidekiq::Sharding::Dispatcher.new('overmatch_detection_')
      Rails.logger.info "[Matching::OverMatchDispatch] 活跃实例: #{dispatcher.active_instance_count}, 玩家数: #{player_addresses.size}"

      player_addresses.each_slice(BATCH_SIZE) do |batch|
        dispatcher.dispatch_batch(Jobs::Matching::OverMatchWorker, batch)
      end
    end

    private

    def fetch_active_player_addresses
      Trading::Order.where(
        onchain_status: %w[pending validated partially_filled],
        offchain_status: %w[active over_matched]
      ).distinct.limit(MAX_PLAYERS_PER_RUN).pluck(:offerer)
    end
  end
end
