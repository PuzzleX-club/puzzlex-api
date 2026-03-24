# frozen_string_literal: true

module Indexer
  # Metadata persistence adapter.
  #
  # Persists metadata fetched by InstanceMetadata providers into
  # ItemIndexer::Metadata and ItemIndexer::Attribute records.
  #
  # This class does NOT fetch metadata itself. Use
  # Metadata::InstanceMetadata::ProviderRegistry.current.fetch()
  # for fetching, then call parse_and_save() to persist the result.
  #
  class MetadataFetcher
    # Persist a metadata hash for a given token instance.
    #
    # @param token_id [String] the token instance ID
    # @param item_id [String] the item ID
    # @param metadata_json [Hash] metadata hash (name, description, image, attributes, etc.)
    def parse_and_save(token_id, item_id, metadata_json)
      normalized_metadata = metadata_json.to_h.deep_stringify_keys

      ApplicationRecord.transaction do
        metadata = ::ItemIndexer::Metadata.find_or_initialize_by(instance_id: token_id)
        metadata.assign_attributes(
          item_id: item_id,
          name: normalized_metadata['name'],
          description: normalized_metadata['description'],
          image: normalized_metadata['image'],
          background_color: normalized_metadata['background_color'],
          raw_metadata: normalized_metadata,
          metadata_fetched_at: Time.current
        )
        metadata.save!

        attributes_array = normalized_metadata['attributes'] || []

        ::ItemIndexer::Attribute.where(instance_id: token_id).destroy_all

        attributes_array.each do |attr|
          next unless attr['trait_type'].present? && attr['value'].present?

          ::ItemIndexer::Attribute.create!(
            instance_id: token_id,
            item_id: item_id,
            trait_type: attr['trait_type'],
            value_string: attr['value'].to_s,
            display_type: attr['display_type']
          )
        end
      end

      Rails.logger.info "[MetadataFetcher] 保存metadata成功 tokenId=#{token_id}, #{normalized_metadata['attributes']&.size || 0}个属性"
    rescue ActiveRecord::RecordNotUnique => e
      Rails.logger.info "[MetadataFetcher] 忽略并发冲突 tokenId=#{token_id}: #{e.message.truncate(100)}"
    end
  end
end
