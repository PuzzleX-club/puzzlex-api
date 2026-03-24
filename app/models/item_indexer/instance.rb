# frozen_string_literal: true

module ItemIndexer
  class Instance < ApplicationRecord
    self.table_name = 'item_indexer_instances'
    self.primary_key = 'id'

    belongs_to :item_record,
               class_name: 'ItemIndexer::Item',
               foreign_key: :item,
               primary_key: :id,
               inverse_of: :instances

    has_many :instance_balances,
             class_name: 'ItemIndexer::InstanceBalance',
             foreign_key: :instance,
             primary_key: :id

    has_many :transactions,
             class_name: 'ItemIndexer::Transaction',
             foreign_key: :instance,
             primary_key: :id

    has_one :metadata,
            class_name: 'ItemIndexer::Metadata',
            foreign_key: :instance_id,
            primary_key: :id,
            dependent: :destroy

    has_many :nft_attributes,
             class_name: 'ItemIndexer::Attribute',
             foreign_key: :instance_id,
             primary_key: :id,
             dependent: :destroy

    validates :id, presence: true, uniqueness: true
    validates :item, :quality, presence: true

    scope :pending_metadata, -> { where(metadata_status: 'pending') }
    scope :queued_metadata, -> { where(metadata_status: 'queued') }
    scope :fetching_metadata, -> { where(metadata_status: 'fetching') }
    scope :completed_metadata, -> { where(metadata_status: 'completed') }
    scope :failed_metadata, -> { where(metadata_status: 'failed').where('metadata_retry_count < ?', 3) }

    def needs_metadata?
      return false unless metadata_enabled?

      %w[pending queued].include?(metadata_status) ||
        (metadata_status == 'failed' && metadata_retry_count < max_retry_count)
    end

    def mark_metadata_fetching!
      update!(
        metadata_status: 'fetching',
        metadata_status_updated_at: Time.current
      )
    end

    def mark_metadata_completed!
      update!(
        metadata_status: 'completed',
        metadata_retry_count: 0,
        metadata_error: nil,
        metadata_status_updated_at: Time.current
      )
    end

    def mark_metadata_failed!(error_message = nil)
      increment(:metadata_retry_count)
      new_status = metadata_retry_count >= max_retry_count ? 'failed' : 'pending'

      update!(
        metadata_status: new_status,
        metadata_error: error_message&.truncate(500),
        metadata_status_updated_at: Time.current
      )

      Rails.logger.error "[ItemIndexer] metadata获取失败 tokenId=#{id}: #{error_message}"
    end

    private

    def metadata_enabled?
      Rails.application.config.x.instance_metadata.enabled
    rescue StandardError
      false
    end

    def max_retry_count
      Rails.application.config.x.instance_metadata.retry_limit || 3
    rescue StandardError
      3
    end
  end
end
