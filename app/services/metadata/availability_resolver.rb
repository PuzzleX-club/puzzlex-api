# frozen_string_literal: true

module Metadata
  # Determines data availability for a given item based on actual query results.
  #
  # This resolver does NOT rely solely on provider registry state (which only
  # tells us "what is configured"), but queries real data to determine what is
  # actually available for a specific item.
  #
  # Availability levels:
  #   :indexed        — on-chain / indexer data exists (full stats available)
  #   :metadata_only  — only catalog/metadata data exists (no chain stats)
  #   :unavailable    — no data found from any source
  #
  class AvailabilityResolver
    INDEXED       = 'indexed'
    METADATA_ONLY = 'metadata_only'
    UNAVAILABLE   = 'unavailable'

    # Resolve data availability for a single item.
    #
    # @param item_id [String, Integer] the item identifier
    # @return [Hash] { data_availability:, provider_key:, provider_family: }
    def self.resolve(item_id)
      # 1. Check indexer (highest fidelity)
      if indexer_has_item?(item_id)
        return {
          data_availability: INDEXED,
          provider_family: 'indexer',
          provider_key: 'indexer'
        }
      end

      # 2. Check catalog (fallback)
      if catalog_has_item?(item_id)
        return {
          data_availability: METADATA_ONLY,
          provider_family: 'catalog',
          provider_key: catalog_provider_key
        }
      end

      # 3. Nothing found
      {
        data_availability: UNAVAILABLE,
        provider_family: 'none',
        provider_key: 'none'
      }
    end

    class << self
      private

      def indexer_has_item?(item_id)
        ItemIndexer::Item.exists?(id: item_id.to_s)
      rescue ActiveRecord::StatementInvalid, ActiveRecord::NoDatabaseError
        false
      end

      def catalog_has_item?(item_id)
        provider = current_catalog_provider
        provider.find_item(item_id).present?
      rescue ActiveRecord::StatementInvalid, ActiveRecord::NoDatabaseError
        false
      end

      def catalog_provider_key
        current_catalog_provider.provider_key
      end

      def current_catalog_provider
        Metadata::Catalog::ProviderRegistry.current
      end
    end
  end
end
