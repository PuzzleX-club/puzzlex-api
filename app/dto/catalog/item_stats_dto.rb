# frozen_string_literal: true

module Catalog
  # Stats and availability context for a catalog item.
  # Provides a stable shape for instance counts, holder counts,
  # and data-source provenance.
  #
  class ItemStatsDTO
    attr_reader :instance_count, :holder_count,
                :data_availability, :provider_family, :provider_key,
                :source

    def initialize(attrs = {})
      @instance_count    = attrs.fetch(:instance_count, 0)
      @holder_count      = attrs.fetch(:holder_count, 0)
      @data_availability = attrs[:data_availability]
      @provider_family   = attrs[:provider_family]
      @provider_key      = attrs[:provider_key]
      # Backward-compat field; canonical judgement uses data_availability + provider_*
      @source            = attrs[:source]
    end

    def as_json(_options = nil)
      {
        instance_count:    instance_count,
        holder_count:      holder_count,
        data_availability: data_availability,
        provider_family:   provider_family,
        provider_key:      provider_key,
        source:            source
      }
    end
  end
end
