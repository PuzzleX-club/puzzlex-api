# frozen_string_literal: true

module ItemIndexer
  class Attribute < ApplicationRecord
    self.table_name = 'item_indexer_attributes'

    belongs_to :metadata_record,
               class_name: 'ItemIndexer::Metadata',
               foreign_key: :instance_id,
               primary_key: :instance_id,
               optional: true

    belongs_to :instance_record,
               class_name: 'ItemIndexer::Instance',
               foreign_key: :instance_id,
               primary_key: :id,
               optional: true

    belongs_to :item_record,
               class_name: 'ItemIndexer::Item',
               foreign_key: :item_id,
               primary_key: :id,
               optional: true

    validates :instance_id, presence: true
    validates :item_id, presence: true
    validates :trait_type, presence: true
    validates :trait_type, uniqueness: { scope: :instance_id }

    before_validation :set_is_fungible
    before_validation :parse_numeric_value

    scope :by_trait_type, ->(type) { where(trait_type: type) }
    scope :fungible, -> { where(is_fungible: true) }
    scope :non_fungible, -> { where(is_fungible: false) }
    scope :numeric_traits, -> { where.not(value_numeric: nil) }
    scope :sorted_by_value, ->(order = :desc) { order(value_numeric: order) }

    # Generic numeric trait ranking for any trait_type.
    # @param item_id [String, Integer] the item ID to scope
    # @param trait_type [String] the trait_type to rank by
    # @param limit [Integer] max results
    def self.trait_ranking(item_id, trait_type:, limit: 100)
      where(item_id: item_id, trait_type: trait_type)
        .where.not(value_numeric: nil)
        .order(value_numeric: :desc)
        .limit(limit)
    end

    def self.attribute_distribution(item_id, trait_type, fungible_only: false)
      query = where(item_id: item_id, trait_type: trait_type)
      query = query.where(is_fungible: true) if fungible_only
      query.group(:value_string).count
    end

    def numeric?
      value_numeric.present?
    end

    def value
      numeric? ? value_numeric : value_string
    end

    private

    def set_is_fungible
      self.is_fungible = display_type.blank?
    end

    def parse_numeric_value
      return unless value_string.present?
      return if value_numeric.present?

      self.value_numeric = BigDecimal(value_string.to_s) if value_string.to_s.match?(/^\d+(\.\d+)?$/)
    rescue ArgumentError, TypeError
      self.value_numeric = nil
    end
  end
end
