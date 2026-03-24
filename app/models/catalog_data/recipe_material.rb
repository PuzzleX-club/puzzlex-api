# frozen_string_literal: true

module CatalogData
  class RecipeMaterial < ApplicationRecord
    belongs_to :recipe,
               class_name: 'CatalogData::Recipe',
               foreign_key: :recipe_id,
               inverse_of: :materials

    belongs_to :item,
               class_name: 'CatalogData::Item',
               foreign_key: :item_id

    validates :recipe, presence: true
    validates :item, presence: true
    validates :quantity, presence: true, numericality: { greater_than: 0 }

    def total_value
      quantity
    end
  end
end
