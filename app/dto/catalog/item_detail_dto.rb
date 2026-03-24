# frozen_string_literal: true

module Catalog
  # Composite DTO for the item detail endpoint.
  # Combines ItemDTO + ItemStatsDTO into a single response shape.
  #
  class ItemDetailDTO
    attr_reader :item, :stats

    def initialize(item:, stats:)
      @item  = item
      @stats = stats
    end

    # Build from an ItemQueryService result hash.
    def self.from_query_result(query_result)
      new(
        item:  query_result[:item_dto],
        stats: query_result[:stats_dto]
      )
    end

    def as_json(_options = nil)
      {
        item:  item.as_json,
        stats: stats.as_json
      }
    end
  end
end
