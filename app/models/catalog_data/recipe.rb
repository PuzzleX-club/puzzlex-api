# frozen_string_literal: true

module CatalogData
  class Recipe < ApplicationRecord
    self.primary_key = 'recipe_id'

    has_many :translations,
             class_name: 'CatalogData::RecipeTranslation',
             foreign_key: :recipe_id,
             dependent: :destroy,
             inverse_of: :recipe

    has_many :materials,
             class_name: 'CatalogData::RecipeMaterial',
             foreign_key: :recipe_id,
             dependent: :destroy

    has_many :products,
             class_name: 'CatalogData::RecipeProduct',
             foreign_key: :recipe_id,
             dependent: :destroy

    has_many :material_items,
             through: :materials,
             source: :item

    has_many :product_items,
             through: :products,
             source: :item

    validates :recipe_id, presence: true, uniqueness: true

    scope :enabled, -> { where(enabled: true) }
    scope :by_type, ->(type) { where(recipe_type: type) }
    scope :by_level, ->(level) { where(level: level) }
    scope :by_proficiency, ->(prof) { where('proficiency <= ?', prof) }

    before_save :update_source_hash

    def name(locale = I18n.locale)
      translation_for(locale)&.name ||
        translations.find_by(locale: 'zh')&.name ||
        translations.find_by(locale: 'zh-CN')&.name ||
        "Recipe##{recipe_id}"
    end

    def description(locale = I18n.locale)
      translation_for(locale)&.description ||
        translations.find_by(locale: 'zh')&.description ||
        translations.find_by(locale: 'zh-CN')&.description
    end

    def available_locales
      translations.pluck(:locale)
    end

    def material_cost
      materials.sum(:quantity)
    end

    def main_product
      products.order(weight: :desc).first
    end

    def materials_with_items
      materials.includes(:item)
    end

    def products_with_items
      products.includes(:item)
    end

    def calculate_source_hash
      hash_data = {
        recipe_id: recipe_id,
        icon: icon,
        classify_level: classify_level,
        display_type: display_type,
        level: level,
        proficiency: proficiency,
        recipes_sort: recipes_sort,
        source_text: source_text,
        time_cost: time_cost,
        times_limit: times_limit,
        recipe_type: recipe_type,
        unlock_condition: unlock_condition,
        unlock_type: unlock_type,
        use_ditamin: use_ditamin,
        use_token: use_token,
        enabled: enabled
      }
      Digest::MD5.hexdigest(hash_data.to_json)
    end

    private

    def translation_for(locale)
      translations.find_by(locale: locale.to_s)
    end

    def update_source_hash
      self.source_hash = calculate_source_hash
    end
  end
end
