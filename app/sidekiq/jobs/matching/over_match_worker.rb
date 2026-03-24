# frozen_string_literal: true

module Jobs::Matching
  class OverMatchWorker
    include Sidekiq::Job

    sidekiq_options queue: :default, retry: 2

    def perform(player_address)
      Matching::OverMatch::Detection.check_player_orders(player_address)
    end
  end
end
