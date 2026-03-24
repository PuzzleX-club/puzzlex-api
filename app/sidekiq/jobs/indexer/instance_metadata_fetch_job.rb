# frozen_string_literal: true

module Jobs
  module Indexer
    class InstanceMetadataFetchJob
      include Sidekiq::Job

      sidekiq_options queue: :metadata_fetch, retry: 3

      def perform(token_id)
        Rails.logger.info "[InstanceMetadataFetchJob] 开始处理 tokenId=#{token_id}"

        # 1. Atomic status check: queued -> fetching
        updated = ItemIndexer::Instance
                    .where(id: token_id, metadata_status: 'queued')
                    .update_all(
                      metadata_status: 'fetching',
                      metadata_status_updated_at: Time.current
                    )

        if updated == 0
          current_status = ItemIndexer::Instance.find_by(id: token_id)&.metadata_status
          Rails.logger.info "[InstanceMetadataFetchJob] ⏭️ 跳过 tokenId=#{token_id}，当前状态: #{current_status || 'not_found'}"
          return
        end

        # 2. Release DB connections before HTTP request
        ActiveRecord::Base.connection_handler.clear_active_connections!

        # 3. Fetch via provider registry
        provider = ::Metadata::InstanceMetadata::ProviderRegistry.current
        result = provider.fetch(token_id)

        # 4. Handle result
        instance = ItemIndexer::Instance.find_by(id: token_id)
        return unless instance

        if result[:success] && result[:metadata]
          begin
            ::Indexer::MetadataFetcher.new.parse_and_save(token_id, instance.item, result[:metadata])
            instance.mark_metadata_completed!
            Rails.logger.info "[InstanceMetadataFetchJob] ✅ 成功处理 tokenId=#{token_id}"
          rescue StandardError => e
            instance.mark_metadata_failed!("Persistence failed: #{e.message}")
            raise
          end
        else
          error_msg = result[:error] || 'Unknown error'
          instance.mark_metadata_failed!(error_msg)
          Rails.logger.error "[InstanceMetadataFetchJob] ❌ 处理失败 tokenId=#{token_id}: #{error_msg}"

          raise "Metadata fetch failed: #{error_msg}" if instance.metadata_retry_count < 3
        end
      rescue StandardError => e
        Rails.logger.error "[InstanceMetadataFetchJob] 异常 tokenId=#{token_id}: #{e.message}"
        Rails.logger.error e.backtrace.first(3).join("\n")
        raise
      end
    end
  end
end
