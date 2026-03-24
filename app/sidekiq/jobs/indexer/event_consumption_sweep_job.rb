module Jobs
  module Indexer
    class EventConsumptionSweepJob
      include Sidekiq::Worker

      BATCH_SIZE = 100

      def perform
        scope = Onchain::LogConsumption.where(status: "pending")
        scope = scope.where("next_retry_at IS NULL OR next_retry_at <= ?", Time.current)
        scope.limit(BATCH_SIZE).pluck(:id).each do |id|
          Jobs::Indexer::EventConsumptionJob.perform_async(id)
        end
      end
    end
  end
end
