# frozen_string_literal: true

module ItemIndexer
  class Item < ApplicationRecord
    self.table_name = 'item_indexer_items'
    self.primary_key = 'id'

    has_many :instances,
             class_name: 'ItemIndexer::Instance',
             foreign_key: :item,
             primary_key: :id,
             inverse_of: :item_record

    has_many :transactions,
             class_name: 'ItemIndexer::Transaction',
             foreign_key: :item,
             primary_key: :id

    validates :id, presence: true, uniqueness: true
  end
end
