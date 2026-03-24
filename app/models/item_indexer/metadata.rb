# frozen_string_literal: true

module ItemIndexer
  class Metadata < ApplicationRecord
    self.table_name = 'item_indexer_metadata'
    self.primary_key = 'instance_id'

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

    has_many :nft_attributes,
             class_name: 'ItemIndexer::Attribute',
             foreign_key: :instance_id,
             primary_key: :instance_id,
             dependent: :destroy

    validates :instance_id, presence: true, uniqueness: true
    validates :item_id, presence: true

    scope :by_item_id, ->(item_id) { where(item_id: item_id) }
    scope :with_attributes, -> { includes(:nft_attributes) }
    scope :recent, -> { order(metadata_fetched_at: :desc) }

    def fungible_attributes
      nft_attributes.where(is_fungible: true)
    end

    def non_fungible_attributes
      nft_attributes.where(is_fungible: false)
    end

    # Generic trait value lookup by trait_type.
    # @param trait_type [String] the trait_type to look up
    # @return the Attribute record, or nil
    def trait_value(trait_type)
      nft_attributes.find_by(trait_type: trait_type)
    end

    def to_json_format
      {
        instance_id: instance_id,
        item_id: item_id,
        name: name,
        description: description,
        image: image,
        background_color: background_color,
        attributes: nft_attributes.map do |attr|
          {
            trait_type: attr.trait_type,
            value: attr.value_string,
            display_type: attr.display_type
          }.compact
        end
      }
    end
  end
end
