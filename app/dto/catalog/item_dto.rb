# frozen_string_literal: true

module Catalog
  # Stable public data shape for the explorer item detail endpoint.
  # Preserves the existing ExplorerItem response contract while moving
  # controller logic behind DTO construction.
  #
  class ItemDTO
    ADVANCE_EXTENSION_FIELDS = %w[
      wealth_value
      drop_scenes
      booth_fees
      destructible
      given_skill_id
      on_chain_delay
      resource_instructions
      token_task_level
      token_task_refresh_type
      user_type
    ].freeze

    attr_reader :id, :total_supply, :minted_amount, :burned_amount,
                :last_updated, :item_info

    def initialize(attrs = {})
      @id            = attrs[:id]
      @total_supply  = attrs[:total_supply]
      @minted_amount = attrs[:minted_amount]
      @burned_amount = attrs[:burned_amount]
      @last_updated  = attrs[:last_updated]
      @item_info     = attrs[:item_info]
    end

    # Build the legacy explorer item shape from an indexer record.
    def self.from_indexer_item(indexer_item, catalog_item: nil, locale: 'zh-CN')
      new(
        id:            indexer_item.id.to_s,
        total_supply:  indexer_item.total_supply.to_s,
        minted_amount: indexer_item.minted_amount.to_s,
        burned_amount: indexer_item.burned_amount.to_s,
        last_updated:  indexer_item.last_updated,
        item_info:     catalog_item ? serialize_catalog_item(catalog_item, locale: locale) : nil
      )
    end

    # Build the legacy explorer item shape from a catalog-only fallback record.
    def self.from_catalog_item(catalog_item, locale: 'zh-CN')
      new(
        id:            catalog_item.item_id.to_s,
        total_supply:  '0',
        minted_amount: '0',
        burned_amount: '0',
        last_updated:  catalog_item.updated_at.to_i,
        item_info:     serialize_catalog_item(catalog_item, locale: locale)
      )
    end

    def as_json(_options = nil)
      {
        id: id,
        total_supply: total_supply,
        minted_amount: minted_amount,
        burned_amount: burned_amount,
        last_updated: last_updated,
        item_info: item_info
      }
    end

    class << self
      private

      def serialize_catalog_item(catalog_item, locale: 'zh-CN')
        translations_index = catalog_item.translations.index_by(&:locale)

        base = {
          item_id: catalog_item.item_id,
          icon: parse_icon_array(catalog_item.icon),
          item_type: catalog_item.item_type,
          sub_type: catalog_item.extra('sub_type'),
          quality: catalog_item.extra('quality', []),
          talent_ids: normalize_talent_ids(catalog_item.extra('talent_ids', [])),
          use_level: catalog_item.extra('use_level')
        }

        advance = {
          can_mint: catalog_item.can_mint,
          sellable: catalog_item.sellable,
          source_hash: catalog_item.source_hash
        }.merge(build_advance_extensions(catalog_item)).compact

        {
          base: base,
          advance: advance.presence,
          translations: catalog_item.translations.map do |translation|
            {
              locale: translation.locale,
              name: translation.name,
              description: translation.description
            }
          end,
          name: translations_index[locale.to_s]&.name ||
                translations_index['zh']&.name ||
                translations_index['zh-CN']&.name ||
                "Item##{catalog_item.item_id}",
          description: translations_index[locale.to_s]&.description ||
                       translations_index['zh']&.description ||
                       translations_index['zh-CN']&.description,
          image_url: parse_icon_array(catalog_item.icon).first
        }
      end

      def normalize_talent_ids(talent_ids_field)
        return [] if talent_ids_field.blank?
        return [] if talent_ids_field.is_a?(Hash) && talent_ids_field.empty?
        return talent_ids_field if talent_ids_field.is_a?(Array)

        Array(talent_ids_field).compact
      rescue StandardError
        []
      end

      def parse_icon_array(icon_field)
        return [] if icon_field.blank?

        if icon_field.is_a?(String)
          trimmed = icon_field.strip
          if trimmed.start_with?('{', '[')
            parsed = JSON.parse(trimmed) rescue nil
            if parsed
              if parsed.is_a?(Hash)
                url = parsed['url'] || parsed['image']
                return url ? [url] : []
              end
              return Array(parsed)
            end
          end
          [trimmed]
        elsif icon_field.is_a?(Array)
          icon_field.compact
        else
          Array(icon_field)
        end
      rescue StandardError
        Array(icon_field)
      end

      def build_advance_extensions(catalog_item)
        allowed_fields = Array(Metadata::Catalog::ProviderRegistry.current.capabilities[:extension_fields]).map(&:to_s)

        ADVANCE_EXTENSION_FIELDS.each_with_object({}) do |field, extensions|
          next unless allowed_fields.include?(field)

          value = catalog_item.extra(field)
          extensions[field.to_sym] = value unless value.nil?
        end
      end
    end
  end
end
