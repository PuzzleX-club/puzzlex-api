# frozen_string_literal: true

module CatalogData
  class Item < ApplicationRecord
    self.primary_key = 'item_id'

    has_many :translations,
             class_name: 'CatalogData::ItemTranslation',
             foreign_key: :item_id,
             dependent: :destroy,
             inverse_of: :item

    has_many :recipe_materials,
             class_name: 'CatalogData::RecipeMaterial',
             foreign_key: :item_id,
             dependent: :destroy

    has_many :recipe_products,
             class_name: 'CatalogData::RecipeProduct',
             foreign_key: :item_id,
             dependent: :destroy

    validates :item_id, presence: true, uniqueness: true
    validates :item_type, presence: true

    scope :enabled, -> { where(enabled: true) }
    scope :mintable, -> { where(can_mint: true) }
    scope :sellable, -> { where(sellable: true) }
    scope :by_type, ->(type) { where(item_type: type) }

    before_save :update_source_hash

    # Read a project-specific field from extra_data JSONB.
    # @param key [String, Symbol] the field name
    # @param default [Object] fallback value if key is absent
    def extra(key, default = nil)
      key = key.to_s
      data = extra_payload
      return default unless data.is_a?(Hash) && data.key?(key)

      data[key]
    end

    def name(locale = I18n.locale)
      translation_for(locale)&.name ||
        translations.find_by(locale: 'zh')&.name ||
        translations.find_by(locale: 'zh-CN')&.name ||
        "Item##{item_id}"
    end

    def description(locale = I18n.locale)
      translation_for(locale)&.description ||
        translations.find_by(locale: 'zh')&.description ||
        translations.find_by(locale: 'zh-CN')&.description
    end

    def available_locales
      translations.pluck(:locale)
    end

    def calculate_source_hash
      hash_data = {
        item_id: item_id,
        icon: icon,
        item_type: item_type,
        can_mint: can_mint,
        sellable: sellable,
        enabled: enabled,
        extra_data: extra_payload
      }
      Digest::MD5.hexdigest(hash_data.to_json)
    end

    private

    def extra_payload
      return {} unless has_attribute?(:extra_data)

      self[:extra_data] || {}
    end

    def translation_for(locale)
      translations.find_by(locale: locale.to_s)
    end

    def update_source_hash
      self.source_hash = calculate_source_hash
    end
  end
end
