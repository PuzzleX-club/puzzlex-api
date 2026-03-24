# frozen_string_literal: true

module ItemIndexer
  class Player < ApplicationRecord
    self.table_name = 'item_indexer_players'
    self.primary_key = 'id'

    has_many :instance_balances,
             class_name: 'ItemIndexer::InstanceBalance',
             foreign_key: :player,
             primary_key: :id

    validates :id, presence: true, uniqueness: true
    validates :address, presence: true

    def self.ensure_player(address)
      normalized = address.to_s.downcase
      normalized = "0x#{normalized}" unless normalized.start_with?('0x')

      find_or_create_by!(id: normalized) do |player|
        player.address = normalized
      end
    end
  end
end
