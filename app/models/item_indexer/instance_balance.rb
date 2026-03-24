# frozen_string_literal: true

module ItemIndexer
  class InstanceBalance < ApplicationRecord
    self.table_name = 'item_indexer_instance_balances'
    self.primary_key = 'id'

    belongs_to :instance_record,
               class_name: 'ItemIndexer::Instance',
               foreign_key: :instance,
               primary_key: :id

    belongs_to :player_record,
               class_name: 'ItemIndexer::Player',
               foreign_key: :player,
               primary_key: :id

    validates :id, presence: true, uniqueness: true
    validates :instance, :player, presence: true

    def self.generate_id(token_id, address)
      "#{token_id}-#{address.to_s.downcase}"
    end

    def self.ensure_balance(token_id, address, timestamp)
      balance_id = generate_id(token_id, address)
      find_or_create_by!(id: balance_id) do |balance|
        balance.instance = token_id
        balance.player = address.to_s.downcase
        balance.balance = 0
        balance.minted_amount = 0
        balance.transferred_in_amount = 0
        balance.transferred_out_amount = 0
        balance.burned_amount = 0
        balance.timestamp = timestamp
      end
    end

    def self.atomic_update(token_id, address, timestamp, changes)
      balance_id = generate_id(token_id, address)
      player_address = address.to_s.downcase

      sql = <<~SQL
        INSERT INTO #{table_name} (id, instance, player, balance, minted_amount,
                                   transferred_in_amount, transferred_out_amount,
                                   burned_amount, timestamp)
        VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)
        ON CONFLICT (id) DO UPDATE SET
          balance = #{table_name}.balance + EXCLUDED.balance,
          minted_amount = #{table_name}.minted_amount + EXCLUDED.minted_amount,
          transferred_in_amount = #{table_name}.transferred_in_amount + EXCLUDED.transferred_in_amount,
          transferred_out_amount = #{table_name}.transferred_out_amount + EXCLUDED.transferred_out_amount,
          burned_amount = #{table_name}.burned_amount + EXCLUDED.burned_amount,
          timestamp = GREATEST(#{table_name}.timestamp, EXCLUDED.timestamp)
      SQL

      connection.exec_query(
        sql,
        'AtomicUpdate',
        [
          balance_id,
          token_id,
          player_address,
          changes[:balance] || 0,
          changes[:minted_amount] || 0,
          changes[:transferred_in_amount] || 0,
          changes[:transferred_out_amount] || 0,
          changes[:burned_amount] || 0,
          timestamp
        ]
      )
    end
  end
end
