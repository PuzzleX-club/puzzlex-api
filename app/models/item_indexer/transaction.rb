# frozen_string_literal: true

module ItemIndexer
  class Transaction < ApplicationRecord
    self.table_name = 'item_indexer_transactions'
    self.primary_key = 'id'

    ZERO_ADDRESS = '0x0000000000000000000000000000000000000000'

    belongs_to :item_record,
               class_name: 'ItemIndexer::Item',
               foreign_key: :item,
               primary_key: :id

    belongs_to :instance_record,
               class_name: 'ItemIndexer::Instance',
               foreign_key: :instance,
               primary_key: :id

    validates :id, presence: true, uniqueness: true
    validates :item, :instance, :transaction_hash, :block_number, :amount, :timestamp, presence: true

    def self.generate_id(tx_hash, log_index, sequence_num = 0)
      hash_hex = tx_hash.to_s.downcase
      hash_hex = "0x#{hash_hex}" unless hash_hex.start_with?("0x")
      "#{hash_hex}-#{log_index}-#{sequence_num}"
    end

    def mint?
      from_address.nil? || from_address == ZERO_ADDRESS
    end

    def burn?
      to_address.nil? || to_address == ZERO_ADDRESS
    end

    def transfer?
      !mint? && !burn?
    end

    def from_address_hex
      from_address || ZERO_ADDRESS
    end

    def to_address_hex
      to_address || ZERO_ADDRESS
    end

    def transaction_hash_hex
      transaction_hash
    end
  end
end
