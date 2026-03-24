# frozen_string_literal: true

module Metadata
  module Catalog
    # Orchestrates multi-source item queries for the explorer show endpoint.
    #
    # Query order:
    #   1. Indexer (on-chain, full stats)
    #   2. Catalog provider (metadata-only fallback)
    #
    # Returns a structured result hash that DTOs can consume,
    # or nil when no source has the item.
    #
    class ItemQueryService
      # @param item_id [String, Integer]
      # @param locale [String]
      # @return [Hash, nil] query result with :item_dto, :stats_dto keys
      def self.call(item_id, locale: 'zh-CN')
        new(item_id, locale: locale).call
      end

      def initialize(item_id, locale: 'zh-CN')
        @item_id = item_id
        @locale  = locale
      end

      def call
        result = try_indexer || try_catalog
        return nil unless result

        result
      end

      private

      attr_reader :item_id, :locale

      # --- Indexer path (highest fidelity) ---

      def try_indexer
        indexer_item = ItemIndexer::Item.find_by(id: item_id.to_s)
        return nil unless indexer_item

        availability = Metadata::AvailabilityResolver.resolve(item_id)
        stats = compute_indexer_stats(indexer_item)

        catalog_item = find_catalog_item
        item_dto = ::Catalog::ItemDTO.from_indexer_item(
          indexer_item,
          catalog_item: catalog_item,
          locale: locale
        )

        stats_dto = ::Catalog::ItemStatsDTO.new(
          instance_count:    stats[:instance_count],
          holder_count:      stats[:holder_count],
          data_availability: availability[:data_availability],
          provider_family:   availability[:provider_family],
          provider_key:      availability[:provider_key],
          source:            'indexer'
        )

        { item_dto: item_dto, stats_dto: stats_dto, item_source: :indexer }
      end

      def compute_indexer_stats(indexer_item)
        instance_count = indexer_item.instances.count
        instances_table = ItemIndexer::Instance.table_name
        balances_table = ItemIndexer::InstanceBalance.table_name
        holder_count = ItemIndexer::InstanceBalance
                         .joins("INNER JOIN #{instances_table} ON #{instances_table}.id = #{balances_table}.instance")
                         .where("#{instances_table}.item = ?", indexer_item.id)
                         .where("#{balances_table}.balance > 0")
                         .distinct
                         .count(:player)

        { instance_count: instance_count, holder_count: holder_count }
      end

      # --- Catalog path (metadata-only fallback) ---

      def try_catalog
        catalog_item = find_catalog_item
        return nil unless catalog_item

        availability = Metadata::AvailabilityResolver.resolve(item_id)

        item_dto = ::Catalog::ItemDTO.from_catalog_item(catalog_item, locale: locale)

        stats_dto = ::Catalog::ItemStatsDTO.new(
          instance_count:    0,
          holder_count:      0,
          data_availability: availability[:data_availability],
          provider_family:   availability[:provider_family],
          provider_key:      availability[:provider_key],
          source:            availability[:provider_key]
        )

        { item_dto: item_dto, stats_dto: stats_dto, item_source: :catalog }
      end

      def find_catalog_item
        catalog_provider.find_item(item_id)
      rescue ActiveRecord::StatementInvalid, ActiveRecord::NoDatabaseError
        nil
      end

      def catalog_provider
        @catalog_provider ||= Metadata::Catalog::ProviderRegistry.current
      end
    end
  end
end
