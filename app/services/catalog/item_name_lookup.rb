# frozen_string_literal: true

module Catalog
  # Unified item name lookup via CatalogData catalog.
  #
  # Usage:
  #   Catalog::ItemNameLookup.call([1, 2, 3], locale: 'en')
  #   # => { 1 => "Iron Sword", 2 => "Wood Shield" }
  #
  # Keys are integers (matching CatalogData::Item.item_id).
  # Use [] with to_i for string-keyed lookups:
  #   map[item_id.to_i]
  #
  # Or use .call_with_string_keys for string-keyed results:
  #   map["99991"] => "Iron Sword"
  #
  class ItemNameLookup
    def self.call(item_ids, locale: I18n.locale)
      return {} if item_ids.blank?

      normalized_locale = normalize_locale(locale)
      ids = Array(item_ids).map(&:to_i).uniq.reject(&:zero?)

      items = CatalogData::Item
        .where(item_id: ids)
        .includes(:translations)

      items.each_with_object({}) do |item, map|
        name = resolve_name(item.translations, normalized_locale) ||
               "Item##{item.item_id}"
        map[item.item_id] = name
        map[item.item_id.to_s] = name
      end
    end

    # Search in-memory (avoids N+1 when translations are eager-loaded)
    def self.resolve_name(translations, locale)
      loaded = translations.to_a
      t = loaded.find { |tr| tr.locale == locale } ||
          loaded.find { |tr| tr.locale == 'zh' } ||
          loaded.find { |tr| tr.locale == 'zh-CN' } ||
          loaded.first
      t&.name
    end
    private_class_method :resolve_name

    def self.normalize_locale(locale)
      case locale.to_s
      when 'cn', 'zh-CN'
        'zh'
      else
        locale.to_s
      end
    end
    private_class_method :normalize_locale
  end
end
