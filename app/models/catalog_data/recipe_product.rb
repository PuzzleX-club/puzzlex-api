# frozen_string_literal: true

module CatalogData
  class RecipeProduct < ApplicationRecord
    belongs_to :recipe,
               class_name: 'CatalogData::Recipe',
               foreign_key: :recipe_id,
               inverse_of: :products

    belongs_to :item,
               class_name: 'CatalogData::Item',
               foreign_key: :item_id

    validates :recipe, presence: true
    validates :item, presence: true
    validates :quantity, presence: true, numericality: { greater_than: 0 }
    validates :weight, numericality: { greater_than_or_equal_to: 0 }

    scope :by_weight, -> { order(weight: :desc) }
    scope :primary, -> { where('weight > 0') }

    def total_value
      quantity
    end

    def primary?
      weight > 0
    end
  end
end
