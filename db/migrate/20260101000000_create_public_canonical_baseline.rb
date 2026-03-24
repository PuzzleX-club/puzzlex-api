# frozen_string_literal: true

# Public canonical baseline migration.
#
# Creates the complete database schema in a single step.
# This replaces the private repo's historical migration chain.
# For fresh installs, either run this migration or use db:schema:load.

class CreatePublicCanonicalBaseline < ActiveRecord::Migration[7.1]
  def change
    enable_extension "plpgsql"
  
    create_table "accounts_user_favorite_items" do |t|
      t.bigint "user_id", null: false
      t.string "item_id", null: false, comment: "favorited item ID"
      t.datetime "created_at", null: false
      t.datetime "updated_at", null: false
      t.index ["user_id", "item_id"], name: "index_accounts_user_favorite_items_on_user_id_and_item_id", unique: true
      t.index ["user_id"], name: "index_accounts_user_favorite_items_on_user_id"
    end
  
    create_table "accounts_user_messages" do |t|
      t.bigint "user_id", null: false
      t.string "project", default: "default", null: false, comment: "project key for multi-project support"
      t.string "message_type", null: false, comment: "message type: order_filled, system_alert, etc."
      t.string "title", null: false, comment: "message title"
      t.text "content", null: false, comment: "message content"
      t.jsonb "data", default: {}, comment: "extra data (order ID, market ID, etc.)"
      t.integer "priority", default: 0, null: false, comment: "priority: 0=normal, 1=important, 2=urgent"
      t.integer "status", default: 0, null: false, comment: "status: 0=unread, 1=read, 2=archived"
      t.datetime "read_at", comment: "read at"
      t.datetime "created_at", null: false
      t.datetime "updated_at", null: false
      t.index ["user_id", "project", "message_type"], name: "idx_user_msg_type"
      t.index ["user_id", "project", "status", "created_at"], name: "idx_user_msg_query"
      t.index ["user_id", "project", "status"], name: "idx_user_msg_unread"
      t.index ["user_id"], name: "index_accounts_user_messages_on_user_id"
    end
  
    create_table "accounts_user_preferences" do |t|
      t.bigint "user_id", null: false
      t.string "project", default: "default", null: false, comment: "project key for multi-project support"
      t.string "key", null: false, comment: "preference key, e.g. trading_preferences"
      t.jsonb "value", default: {}, null: false, comment: "preference value (JSON)"
      t.integer "version", default: 1, null: false, comment: "data version for format migration"
      t.datetime "created_at", null: false
      t.datetime "updated_at", null: false
      t.index ["user_id", "project", "key"], name: "idx_user_pref_unique", unique: true
      t.index ["user_id", "project"], name: "idx_user_pref_user_project"
      t.index ["user_id"], name: "index_accounts_user_preferences_on_user_id"
    end
  
    create_table "accounts_users" do |t|
      t.string "address"
      t.datetime "created_at", null: false
      t.datetime "updated_at", null: false
      t.integer "admin_level", default: 0, null: false
      t.index ["address"], name: "index_accounts_users_on_address", unique: true
      t.index ["admin_level"], name: "index_accounts_users_on_admin_level"
    end
  
    create_table "catalog_item_translations" do |t|
      t.integer "item_id", null: false
      t.string "locale", limit: 5, null: false
      t.string "name", null: false
      t.text "description"
      t.string "translation_hash"
      t.datetime "created_at", null: false
      t.datetime "updated_at", null: false
      t.index ["item_id", "locale"], name: "index_catalog_item_translations_on_item_id_and_locale", unique: true
      t.index ["locale"], name: "index_catalog_item_translations_on_locale"
      t.index ["name"], name: "index_catalog_item_translations_on_name"
      t.index ["translation_hash"], name: "index_catalog_item_translations_on_translation_hash"
    end
  
    create_table "catalog_items", primary_key: "item_id", id: :serial do |t|
      t.string "icon"
      t.integer "item_type", null: false
      t.boolean "can_mint"
      t.boolean "sellable"
      t.string "source_hash"
      t.datetime "created_at", null: false
      t.datetime "updated_at", null: false
      t.boolean "enabled", default: true, null: false
      t.jsonb "extra_data", default: {}, null: false
      t.index ["can_mint"], name: "index_catalog_items_on_can_mint"
      t.index ["enabled"], name: "index_catalog_items_on_enabled"
      t.index ["extra_data"], name: "index_catalog_items_on_extra_data", using: :gin
      t.index ["item_type"], name: "index_catalog_items_on_item_type"
      t.index ["source_hash"], name: "index_catalog_items_on_source_hash"
    end
  
    create_table "catalog_recipe_materials" do |t|
      t.integer "recipe_id", null: false
      t.integer "item_id", null: false
      t.integer "quantity", default: 1, null: false
      t.datetime "created_at", null: false
      t.datetime "updated_at", null: false
      t.index ["item_id"], name: "index_catalog_recipe_materials_on_item_id"
      t.index ["recipe_id"], name: "index_catalog_recipe_materials_on_recipe_id"
    end
  
    create_table "catalog_recipe_products" do |t|
      t.integer "recipe_id", null: false
      t.integer "item_id", null: false
      t.integer "quantity", default: 1, null: false
      t.integer "weight", default: 0
      t.integer "product_type"
      t.datetime "created_at", null: false
      t.datetime "updated_at", null: false
      t.index ["item_id"], name: "index_catalog_recipe_products_on_item_id"
      t.index ["recipe_id"], name: "index_catalog_recipe_products_on_recipe_id"
    end
  
    create_table "catalog_recipe_translations" do |t|
      t.integer "recipe_id", null: false
      t.string "locale", limit: 5, null: false
      t.string "name", null: false
      t.text "description"
      t.string "translation_hash"
      t.datetime "created_at", null: false
      t.datetime "updated_at", null: false
      t.index ["locale"], name: "index_catalog_recipe_translations_on_locale"
      t.index ["recipe_id", "locale"], name: "index_catalog_recipe_translations_on_recipe_id_and_locale", unique: true
      t.index ["translation_hash"], name: "index_catalog_recipe_translations_on_translation_hash"
    end
  
    create_table "catalog_recipes", primary_key: "recipe_id", id: :serial do |t|
      t.string "icon"
      t.integer "classify_level"
      t.integer "display_type"
      t.integer "level"
      t.integer "proficiency"
      t.integer "recipes_sort"
      t.integer "source_text"
      t.integer "time_cost"
      t.integer "times_limit"
      t.integer "recipe_type"
      t.integer "unlock_condition"
      t.integer "unlock_type"
      t.integer "use_ditamin"
      t.integer "use_token"
      t.boolean "enabled", default: true
      t.string "source_hash"
      t.datetime "created_at", null: false
      t.datetime "updated_at", null: false
      t.index ["enabled"], name: "index_catalog_recipes_on_enabled"
      t.index ["recipe_type"], name: "index_catalog_recipes_on_recipe_type"
      t.index ["source_hash"], name: "index_catalog_recipes_on_source_hash"
    end
  
    create_table "item_indexer_attributes" do |t|
      t.string "instance_id", null: false, comment: "associated tokenId"
      t.string "item_id", null: false, comment: "associated itemId (denormalized for queries)"
      t.string "trait_type", null: false, comment: "attribute type (e.g. Quality, Type, WealthValue)"
      t.string "value_string", comment: "string value"
      t.decimal "value_numeric", precision: 20, scale: 6, comment: "numeric value (for sorting)"
      t.string "display_type", comment: "display type (non-fungible when present)"
      t.boolean "is_fungible", default: true, null: false, comment: "fungible attribute (true when no display_type)"
      t.datetime "created_at", null: false
      t.datetime "updated_at", null: false
      t.index ["instance_id", "trait_type"], name: "idx_attr_unique", unique: true
      t.index ["is_fungible"], name: "idx_attr_fungible"
      t.index ["item_id", "trait_type", "value_numeric"], name: "idx_attr_item_trait_value"
      t.index ["trait_type", "value_numeric"], name: "idx_attr_trait_value"
    end
  
    create_table "item_indexer_instance_balances", id: { type: :string, comment: "{tokenId}-{address}" } do |t|
      t.string "instance", null: false, comment: "associated tokenId"
      t.string "player", null: false, comment: "associated player address"
      t.decimal "balance", precision: 78, default: "0", null: false, comment: "current balance"
      t.decimal "minted_amount", precision: 78, default: "0", null: false, comment: "cumulative minted amount"
      t.decimal "transferred_in_amount", precision: 78, default: "0", null: false, comment: "cumulative transferred-in amount"
      t.decimal "transferred_out_amount", precision: 78, default: "0", null: false, comment: "cumulative transferred-out amount"
      t.decimal "burned_amount", precision: 78, default: "0", null: false, comment: "cumulative burned amount"
      t.bigint "timestamp", null: false, comment: "last updated timestamp"
      t.index ["balance"], name: "idx_item_indexer_balances_balance"
      t.index ["instance"], name: "idx_item_indexer_balances_instance"
      t.index ["player"], name: "idx_item_indexer_balances_player"
    end
  
    create_table "item_indexer_instances", id: { type: :string, comment: "tokenId (完整结构化ID)" } do |t|
      t.decimal "total_supply", precision: 78, default: "0", null: false, comment: "current total supply"
      t.decimal "minted_amount", precision: 78, default: "0", null: false, comment: "cumulative minted total"
      t.decimal "burned_amount", precision: 78, default: "0", null: false, comment: "cumulative burned total"
      t.string "item", null: false, comment: "associated itemId"
      t.string "quality", null: false, comment: "quality (e.g. 0x10)"
      t.bigint "last_updated", null: false, comment: "last updated timestamp"
      t.string "metadata_status", default: "pending", comment: "metadata fetch status: pending/fetching/completed/failed"
      t.integer "metadata_retry_count", default: 0, comment: "metadata fetch retry count"
      t.string "metadata_error", comment: "last metadata fetch error"
      t.datetime "metadata_status_updated_at", comment: "metadata status last updated (for timeout detection)"
      t.index ["item"], name: "idx_item_indexer_instances_item"
      t.index ["metadata_status", "id"], name: "idx_instances_metadata_status_id"
      t.index ["metadata_status", "metadata_status_updated_at"], name: "idx_instances_metadata_status_time"
      t.index ["metadata_status"], name: "idx_instances_metadata_status"
    end
  
    create_table "item_indexer_items", id: { type: :string, comment: "itemId (从tokenId提取)" } do |t|
      t.decimal "total_supply", precision: 78, default: "0", null: false, comment: "current total supply"
      t.decimal "minted_amount", precision: 78, default: "0", null: false, comment: "cumulative minted total"
      t.decimal "burned_amount", precision: 78, default: "0", null: false, comment: "cumulative burned total"
      t.bigint "last_updated", null: false, comment: "last updated timestamp"
    end
  
    create_table "item_indexer_metadata", primary_key: "instance_id", id: { type: :string, comment: "tokenId" } do |t|
      t.string "item_id", null: false, comment: "itemId"
      t.string "name", comment: "NFT name"
      t.text "description", comment: "NFT description"
      t.string "image", comment: "image URL"
      t.string "background_color", comment: "background color"
      t.json "raw_metadata", comment: "complete raw metadata JSON"
      t.datetime "metadata_fetched_at", comment: "metadata fetched at"
      t.datetime "created_at", null: false
      t.datetime "updated_at", null: false
      t.index ["item_id"], name: "idx_metadata_item_id"
    end
  
    create_table "item_indexer_players", id: { type: :string, comment: "hex address (lowercase)" } do |t|
      t.string "address", null: false
    end
  
    create_table "item_indexer_transactions", id: { type: :string, comment: "{txHash}-{logIndex}-{sequenceNum}" } do |t|
      t.string "item", null: false, comment: "associated itemId"
      t.string "instance", null: false, comment: "associated tokenId"
      t.bigint "log_index", null: false, comment: "log index"
      t.bigint "block_number", null: false, comment: "block number"
      t.decimal "amount", precision: 78, null: false, comment: "transfer amount"
      t.bigint "timestamp", null: false, comment: "block timestamp"
      t.string "transaction_hash", null: false
      t.string "block_hash", null: false
      t.string "from_address"
      t.string "to_address"
      t.index ["block_number"], name: "idx_item_indexer_tx_block"
      t.index ["instance"], name: "idx_item_indexer_tx_instance"
      t.index ["item"], name: "idx_item_indexer_tx_item"
      t.index ["transaction_hash", "log_index"], name: "idx_item_indexer_tx_hash_log"
    end
  
    create_table "merkle_tree_nodes" do |t|
      t.string "snapshot_id", limit: 100, null: false, comment: "snapshot ID format: {item_id}-{timestamp}"
      t.integer "node_index", null: false
      t.integer "level", null: false
      t.string "node_hash", limit: 66, null: false, comment: "Keccak256 hash (0x + 64 hex chars)"
      t.integer "parent_index"
      t.boolean "is_leaf", default: false, null: false
      t.string "token_id", limit: 100, comment: "NFT token ID (leaf nodes only)"
      t.datetime "created_at", null: false
      t.datetime "updated_at", null: false
      t.string "item_id", limit: 50, comment: "item ID (root nodes only)"
      t.boolean "is_root", default: false, null: false
      t.integer "tree_height", comment: "tree height (root nodes only)"
      t.integer "total_tokens", comment: "total token count (root nodes only)"
      t.index ["created_at", "snapshot_id"], name: "idx_cleanup_by_time", comment: "cleanup by time"
      t.index ["item_id", "is_root", "created_at"], name: "idx_latest_root_lookup", comment: "latest root lookup by item_id"
      t.index ["node_hash", "is_root"], name: "idx_criteria_lookup", comment: "criteria hash lookup"
      t.index ["node_hash"], name: "idx_node_hash", comment: "hash lookup"
      t.index ["snapshot_id", "is_leaf", "token_id"], name: "idx_snapshot_leaf_token", comment: "leaf and token lookup"
      t.index ["snapshot_id", "is_root"], name: "idx_snapshot_root", comment: "root node lookup"
      t.index ["snapshot_id", "level", "node_index"], name: "idx_merkle_nodes_snapshot_level_node", unique: true
      t.check_constraint "is_leaf = true AND token_id IS NOT NULL OR is_leaf = false AND token_id IS NULL", name: "chk_leaf_token_consistency"
      t.check_constraint "is_root = true AND item_id IS NOT NULL OR is_root = false", name: "chk_root_item_consistency"
      t.check_constraint "level >= 0", name: "chk_level_non_negative"
      t.check_constraint "node_index >= 0", name: "chk_node_index_non_negative"
    end
  
    create_table "merkle_tree_roots" do |t|
      t.string "root_hash", limit: 66, null: false, comment: "Merkle tree root hash (0x + 64 hex chars)"
      t.string "item_id", limit: 50, null: false, comment: "associated item ID"
      t.string "snapshot_id", limit: 100, null: false, comment: "snapshot ID, references merkle_tree_nodes"
      t.integer "token_count", default: 0, null: false, comment: "token count in this root"
      t.boolean "tree_exists", default: true, null: false, comment: "whether linked Merkle tree data still exists"
      t.datetime "tree_deleted_at", comment: "when Merkle tree data was deleted"
      t.text "metadata", comment: "extra metadata (JSON)"
      t.datetime "created_at", null: false
      t.datetime "updated_at", null: false
      t.integer "tree_height", comment: "Merkle tree height"
      t.integer "generation_duration_ms", comment: "generation duration (ms)"
      t.datetime "last_used_at", comment: "last used at"
      t.integer "usage_count", default: 0, comment: "usage count"
      t.datetime "expires_at", comment: "expected expiry (created_at + 10 days)"
      t.index ["expires_at", "tree_exists"], name: "idx_expiry_status", comment: "expiry status lookup"
      t.index ["item_id", "created_at"], name: "index_merkle_tree_roots_on_item_id_and_created_at", comment: "lookup by item_id and created_at"
      t.index ["item_id", "tree_exists", "created_at"], name: "idx_item_active_recent", comment: "latest active root lookup"
      t.index ["last_used_at"], name: "idx_last_used", comment: "usage analysis"
      t.index ["root_hash"], name: "index_merkle_tree_roots_on_root_hash", unique: true, comment: "unique root hash"
      t.index ["snapshot_id"], name: "index_merkle_tree_roots_on_snapshot_id", comment: "snapshot ID lookup"
      t.index ["tree_exists", "created_at"], name: "index_merkle_tree_roots_on_tree_exists_and_created_at", comment: "active root lookup"
      t.check_constraint "generation_duration_ms >= 0", name: "chk_generation_duration_non_negative"
      t.check_constraint "token_count > 0", name: "chk_token_count_positive"
      t.check_constraint "tree_height > 0", name: "chk_tree_height_positive"
      t.check_constraint "usage_count >= 0", name: "chk_usage_count_non_negative"
    end
  
    create_table "onchain_event_listener_statuses" do |t|
      t.bigint "last_processed_block", null: false
      t.datetime "last_updated_at"
      t.datetime "created_at", null: false
      t.datetime "updated_at", null: false
      t.string "event_type", default: "global", null: false
      t.index ["event_type"], name: "index_onchain_event_listener_statuses_on_event_type", unique: true
    end
  
    create_table "onchain_event_retry_ranges" do |t|
      t.string "event_type", null: false, comment: "event type (e.g. OrderFulfilled, OrderValidated)"
      t.integer "from_block", null: false, comment: "retry block range start"
      t.integer "to_block", null: false, comment: "retry block range end"
      t.integer "attempts", default: 0, null: false, comment: "retry count"
      t.text "last_error", comment: "last error message"
      t.datetime "next_retry_at", comment: "next retry at"
      t.datetime "created_at", null: false
      t.datetime "updated_at", null: false
      t.index ["event_type", "from_block", "to_block"], name: "index_retry_ranges_on_type_and_blocks"
      t.index ["event_type"], name: "index_onchain_event_retry_ranges_on_event_type"
    end
  
    create_table "onchain_event_subscriptions" do |t|
      t.string "handler_key", null: false
      t.string "abi_key", null: false
      t.jsonb "addresses", default: [], null: false
      t.jsonb "topics", default: [], null: false
      t.jsonb "topic0_mapping", default: {}, null: false
      t.bigint "start_block", default: 0, null: false
      t.integer "block_window", default: 90, null: false
      t.datetime "created_at", null: false
      t.datetime "updated_at", null: false
      t.index ["handler_key"], name: "index_onchain_event_subscriptions_on_handler_key", unique: true
    end
  
    create_table "onchain_log_consumptions" do |t|
      t.bigint "raw_log_id", null: false
      t.string "handler_key", null: false
      t.string "status", default: "pending", null: false
      t.integer "attempts", default: 0, null: false
      t.text "last_error"
      t.datetime "next_retry_at"
      t.datetime "consumed_at"
      t.datetime "created_at", null: false
      t.datetime "updated_at", null: false
      t.index ["raw_log_id", "handler_key"], name: "index_onchain_log_consumptions_on_raw_and_handler", unique: true
      t.index ["raw_log_id"], name: "index_onchain_log_consumptions_on_raw_log_id"
      t.index ["status"], name: "index_onchain_log_consumptions_on_status"
    end
  
    create_table "onchain_raw_logs" do |t|
      t.string "address", null: false
      t.string "event_name"
      t.string "topic0", null: false
      t.jsonb "topics", default: [], null: false
      t.text "data", null: false
      t.bigint "block_number", null: false
      t.string "block_hash"
      t.string "transaction_hash", null: false
      t.integer "log_index", null: false
      t.integer "transaction_index"
      t.integer "block_timestamp"
      t.jsonb "decoded_payload"
      t.datetime "created_at", null: false
      t.datetime "updated_at", null: false
      t.index ["address"], name: "index_onchain_raw_logs_on_address"
      t.index ["block_number", "log_index", "transaction_hash"], name: "index_onchain_raw_logs_on_block_tx_log", unique: true
      t.index ["event_name"], name: "index_onchain_raw_logs_on_event_name"
    end
  
    create_table "trading_counter_events" do |t|
      t.string "event_name", null: false
      t.bigint "new_counter"
      t.string "offerer"
      t.datetime "created_at", null: false
      t.datetime "updated_at", null: false
      t.string "transaction_hash", null: false
      t.integer "log_index", null: false
      t.integer "block_number", comment: "block number of the event"
      t.datetime "block_timestamp", comment: "block timestamp"
      t.index ["event_name"], name: "index_trading_counter_events_on_event_name"
      t.index ["offerer"], name: "index_trading_counter_events_on_offerer"
      t.index ["transaction_hash", "log_index"], name: "index_trading_counter_events_on_transaction_and_log_index", unique: true
    end
  
    create_table "trading_klines" do |t|
      t.integer "market_id", null: false
      t.integer "interval", null: false
      t.integer "timestamp", null: false
      t.decimal "volume", precision: 18, scale: 8, default: "0.0", null: false
      t.datetime "created_at", null: false
      t.datetime "updated_at", null: false
      t.decimal "open", precision: 30
      t.decimal "high", precision: 30
      t.decimal "low", precision: 30
      t.decimal "close", precision: 30
      t.decimal "turnover", precision: 30
      t.index ["market_id", "interval", "timestamp"], name: "index_trading_klines_on_market_id_and_interval_and_timestamp", unique: true
      t.index ["timestamp"], name: "index_trading_klines_on_timestamp"
    end
  
    create_table "trading_market_fill_events" do |t|
      t.bigint "order_fill_id", null: false
      t.bigint "market_id", null: false
      t.bigint "block_timestamp", null: false
      t.decimal "price_wei", precision: 78, null: false
      t.decimal "filled_amount", precision: 78, default: "0", null: false
      t.decimal "turnover_wei", precision: 78, default: "0", null: false
      t.boolean "processed", default: false, null: false
      t.datetime "processed_at"
      t.datetime "created_at", null: false
      t.datetime "updated_at", null: false
      t.index ["market_id", "block_timestamp"], name: "index_trading_market_fill_events_on_market_and_ts"
      t.index ["order_fill_id"], name: "index_trading_market_fill_events_on_order_fill_id", unique: true
      t.index ["processed"], name: "index_trading_market_fill_events_on_processed"
    end
  
    create_table "trading_market_intraday_stats", primary_key: "market_id" do |t|
      t.bigint "window_end_ts", null: false
      t.decimal "open_price_wei", precision: 78, null: false
      t.decimal "high_price_wei", precision: 78, null: false
      t.decimal "low_price_wei", precision: 78, null: false
      t.decimal "close_price_wei", precision: 78, null: false
      t.decimal "volume", precision: 40, scale: 18, default: "0.0", null: false
      t.decimal "turnover_wei", precision: 78, default: "0", null: false
      t.integer "fill_count", default: 0, null: false
      t.bigint "last_processed_event_id"
      t.datetime "created_at", null: false
      t.datetime "updated_at", null: false
      t.bigint "window_start_ts", default: 0, null: false
      t.boolean "has_trade", default: false, null: false
      t.decimal "last_price_wei", precision: 78, default: "0", null: false
      t.index ["window_end_ts"], name: "index_trading_market_intraday_stats_on_window_end"
    end
  
    create_table "trading_market_summaries" do |t|
      t.string "market_id", null: false
      t.bigint "item_id"
      t.integer "bid_count", default: 0, null: false
      t.integer "ask_count", default: 0, null: false
      t.decimal "bid_amount", precision: 30, default: "0", null: false
      t.decimal "ask_amount", precision: 30, default: "0", null: false
      t.decimal "best_bid_price", precision: 78
      t.decimal "best_ask_price", precision: 78
      t.string "best_bid_order_hash"
      t.string "best_ask_order_hash"
      t.decimal "spread", precision: 78
      t.boolean "dirty", default: false, null: false
      t.datetime "dirty_at"
      t.datetime "created_at", null: false
      t.datetime "updated_at", null: false
      t.decimal "last_trade_price", precision: 78
      t.datetime "last_trade_at"
      t.decimal "price_change_24h_pct", precision: 10, scale: 2
      t.index ["dirty"], name: "index_trading_market_summaries_on_dirty"
      t.index ["market_id"], name: "index_trading_market_summaries_on_market_id", unique: true
    end
  
    create_table "trading_markets" do |t|
      t.string "name", null: false
      t.string "base_currency", null: false
      t.string "quote_currency", null: false
      t.string "price_address", null: false
      t.integer "item_id", null: false
      t.string "market_id", null: false
      t.datetime "created_at", null: false
      t.datetime "updated_at", null: false
      t.integer "payment_type", default: 1
      t.index ["base_currency", "quote_currency"], name: "index_trading_markets_on_base_currency_and_quote_currency", unique: true
      t.index ["market_id"], name: "index_trading_markets_on_market_id", unique: true
      t.index ["payment_type"], name: "index_trading_markets_on_payment_type"
    end
  
    create_table "trading_order_events" do |t|
      t.string "event_name", null: false
      t.string "order_hash"
      t.string "offerer"
      t.string "zone"
      t.string "recipient"
      t.jsonb "offer", default: {}
      t.jsonb "consideration", default: {}
      t.jsonb "matched_orders", default: {}
      t.datetime "created_at", null: false
      t.datetime "updated_at", null: false
      t.string "transaction_hash", null: false
      t.integer "log_index", null: false
      t.integer "block_number", comment: "block number of the event"
      t.bigint "block_timestamp", comment: "block timestamp"
      t.boolean "synced", default: false
      t.index ["event_name", "order_hash"], name: "index_trading_order_events_on_event_name_and_order_hash"
      t.index ["order_hash"], name: "index_trading_order_events_on_order_hash"
      t.index ["transaction_hash", "log_index"], name: "index_trading_order_events_on_transaction_and_log_index", unique: true
    end
  
    create_table "trading_order_fills" do |t|
      t.bigint "order_id", null: false
      t.bigint "order_item_id", null: false
      t.decimal "filled_amount", precision: 78, default: "0", null: false
      t.jsonb "price_distribution", default: {}, null: false
      t.string "transaction_hash"
      t.integer "log_index"
      t.integer "block_timestamp"
      t.datetime "created_at", null: false
      t.datetime "updated_at", null: false
      t.bigint "market_id"
      t.string "buyer_address", limit: 42, comment: "buyer address"
      t.string "seller_address", limit: 42, comment: "seller address"
      t.bigint "event_id", comment: "OrderFulfilled event ID that created this fill"
      t.bigint "matched_event_id", comment: "related OrdersMatched event ID"
      t.index ["buyer_address", "id"], name: "index_trading_order_fills_on_buyer_address_id"
      t.index ["buyer_address"], name: "idx_trading_order_fills_buyer_address"
      t.index ["event_id"], name: "idx_trading_order_fills_event_id"
      t.index ["market_id", "block_timestamp", "id"], name: "index_trading_order_fills_on_market_id_block_ts_id", order: { block_timestamp: :desc, id: :desc }
      t.index ["market_id", "id"], name: "index_trading_order_fills_on_market_id_id"
      t.index ["market_id"], name: "index_trading_order_fills_on_market_id"
      t.index ["matched_event_id"], name: "idx_trading_order_fills_matched_event_id"
      t.index ["order_id"], name: "index_trading_order_fills_on_order_id"
      t.index ["order_item_id"], name: "index_trading_order_fills_on_order_item_id"
      t.index ["seller_address", "id"], name: "index_trading_order_fills_on_seller_address_id"
      t.index ["seller_address"], name: "idx_trading_order_fills_seller_address"
      t.index ["transaction_hash", "log_index"], name: "index_trading_order_fills_on_tx_hash_and_log_idx", unique: true
    end
  
    create_table "trading_order_items" do |t|
      t.bigint "order_id", null: false
      t.string "role", null: false
      t.string "token_address", null: false
      t.string "token_id"
      t.decimal "start_amount", precision: 78, default: "0", null: false
      t.decimal "end_amount", precision: 78, default: "0", null: false
      t.jsonb "start_price_distribution", default: {}, null: false
      t.jsonb "end_price_distribution", default: {}, null: false
      t.datetime "created_at", null: false
      t.datetime "updated_at", null: false
      t.index ["order_id"], name: "index_trading_order_items_on_order_id"
    end
  
    create_table "trading_order_matching_logs" do |t|
      t.string "market_id", null: false, comment: "market identifier"
      t.string "matching_session_id", null: false, comment: "matching session ID (UUID)"
      t.string "trigger_source", comment: "trigger source (new_order/scheduled/manual)"
      t.string "status", default: "started", null: false, comment: "matching status: started/completed/failed/cancelled"
      t.text "failure_reason", comment: "failure reason"
      t.integer "input_bids_count", default: 0, comment: "input bid count"
      t.integer "input_asks_count", default: 0, comment: "input ask count"
      t.json "input_bids_summary", comment: "bid summary"
      t.json "input_asks_summary", comment: "ask summary"
      t.integer "validated_bids_count", default: 0, comment: "validated bid count"
      t.integer "validated_asks_count", default: 0, comment: "validated ask count"
      t.integer "filtered_bids_count", default: 0, comment: "filtered bid count"
      t.integer "filtered_asks_count", default: 0, comment: "filtered ask count"
      t.json "filter_reasons", comment: "filter reason stats"
      t.string "algorithm_used", comment: "algorithm used (dp/recursive/hybrid)"
      t.integer "matched_groups_count", default: 0, comment: "matched group count"
      t.integer "matched_orders_count", default: 0, comment: "total matched order count"
      t.json "matching_details", comment: "matching details"
      t.datetime "started_at", null: false, comment: "matching started at"
      t.datetime "validation_completed_at", comment: "validation completed at"
      t.datetime "matching_completed_at", comment: "matching completed at"
      t.datetime "completed_at", comment: "fully completed at"
      t.integer "total_duration_ms", comment: "total duration (ms)"
      t.integer "validation_duration_ms", comment: "validation duration (ms)"
      t.integer "matching_duration_ms", comment: "matching duration (ms)"
      t.json "cache_stats", comment: "cache hit stats"
      t.json "performance_metrics", comment: "performance metrics"
      t.string "redis_status_before", comment: "Redis status before matching"
      t.string "redis_status_after", comment: "Redis status after matching"
      t.json "redis_data_stored", comment: "Redis data stored summary"
      t.text "error_message", comment: "error message"
      t.text "error_backtrace", comment: "error backtrace"
      t.json "warnings", comment: "warning list"
      t.string "worker_id", comment: "worker ID"
      t.string "server_info", comment: "server info"
      t.json "environment_info", comment: "environment info"
      t.datetime "created_at", null: false
      t.datetime "updated_at", null: false
      t.json "queue_operations", comment: "queue operation history"
      t.integer "queue_entry_count", default: 0, comment: "enqueue count"
      t.integer "queue_exit_count", default: 0, comment: "dequeue count"
      t.integer "recovery_attempts", default: 0, comment: "recovery attempt count"
      t.integer "timeout_events", default: 0, comment: "timeout event count"
      t.index ["algorithm_used"], name: "index_trading_order_matching_logs_on_algorithm_used", comment: "algorithm type index"
      t.index ["market_id", "started_at"], name: "index_trading_order_matching_logs_on_market_id_and_started_at", comment: "market + time index"
      t.index ["market_id"], name: "index_trading_order_matching_logs_on_market_id", comment: "market query index"
      t.index ["matching_session_id"], name: "index_trading_order_matching_logs_on_matching_session_id", unique: true, comment: "unique session ID"
      t.index ["queue_entry_count"], name: "index_trading_order_matching_logs_on_queue_entry_count", comment: "enqueue stats index"
      t.index ["recovery_attempts"], name: "index_trading_order_matching_logs_on_recovery_attempts", comment: "recovery stats index"
      t.index ["started_at"], name: "index_trading_order_matching_logs_on_started_at", comment: "time range query index"
      t.index ["status"], name: "index_trading_order_matching_logs_on_status", comment: "status query index"
      t.index ["trigger_source"], name: "index_trading_order_matching_logs_on_trigger_source", comment: "trigger source index"
    end
  
    create_table "trading_order_status_backups" do |t|
      t.string "order_hash", null: false, comment: "order hash"
      t.string "original_off_chain_status", comment: "original offchain status"
      t.string "over_matched_reason", null: false, comment: "over-match reason"
      t.string "resource_id", null: false, comment: "insufficient resource ID"
      t.datetime "backed_up_at", precision: nil, null: false, comment: "backed up at"
      t.datetime "restored_at", precision: nil, comment: "restored at (soft delete marker)"
      t.boolean "is_active", default: true, null: false, comment: "active backup (false = restored)"
      t.datetime "created_at", null: false
      t.datetime "updated_at", null: false
      t.index ["backed_up_at"], name: "index_order_backup_on_backed_up_at"
      t.index ["is_active"], name: "index_order_backup_on_active"
      t.index ["order_hash", "is_active"], name: "index_order_backup_on_hash_active"
      t.index ["order_hash"], name: "index_order_backup_on_hash"
      t.index ["over_matched_reason"], name: "index_order_backup_on_reason"
      t.index ["resource_id"], name: "index_order_backup_on_resource_id"
      t.index ["restored_at"], name: "index_order_backup_on_restored_at"
    end
  
    create_table "trading_order_status_logs" do |t|
      t.bigint "order_id", null: false
      t.string "status_type", null: false
      t.string "from_status"
      t.string "to_status", null: false
      t.string "reason"
      t.jsonb "metadata", default: {}, null: false
      t.datetime "changed_at", null: false
      t.datetime "created_at", null: false
      t.datetime "updated_at", null: false
      t.index ["order_id", "status_type", "changed_at"], name: "idx_on_order_id_status_type_changed_at_1d1e1d4088"
      t.index ["order_id"], name: "index_trading_order_status_logs_on_order_id"
    end
  
    create_table "trading_orders" do |t|
      t.string "order_hash"
      t.json "parameters"
      t.string "signature"
      t.string "offerer"
      t.string "start_time"
      t.string "end_time"
      t.string "offer_token"
      t.string "offer_identifier"
      t.string "consideration_token"
      t.string "consideration_identifier"
      t.integer "counter"
      t.boolean "is_validated", default: false
      t.boolean "is_cancelled", default: false
      t.bigint "total_filled", default: 0
      t.bigint "total_size", default: 0
      t.string "order_direction"
      t.decimal "start_price", precision: 78
      t.decimal "end_price", precision: 78
      t.decimal "consideration_start_amount", precision: 78
      t.decimal "consideration_end_amount", precision: 78
      t.decimal "offer_start_amount", precision: 78
      t.decimal "offer_end_amount", precision: 78
      t.datetime "created_at", null: false
      t.datetime "updated_at", null: false
      t.string "onchain_status", default: "pending", null: false, comment: "order status: pending, completed, canceled, etc."
      t.jsonb "synced_at", comment: "sync timestamps and transaction data"
      t.bigint "offer_item_id"
      t.bigint "consideration_item_id"
      t.string "market_id"
      t.string "offchain_status", comment: "offchain status: 0=active, 1=over-matched, 2=expired, 3=paused"
      t.datetime "offchain_status_updated_at", precision: nil, comment: "offchain status last updated"
      t.text "offchain_status_reason", comment: "offchain status change reason"
      t.integer "order_type", default: 3, null: false, comment: "Seaport OrderType: 0=FULL_OPEN, 1=PARTIAL_OPEN, 2=FULL_RESTRICTED, 3=PARTIAL_RESTRICTED, 4=CONTRACT"
      t.integer "offer_item_type", comment: "Seaport ItemType for offer items: 0=NATIVE(ETH/MATIC), 1=ERC20, 2=ERC721, 3=ERC1155, 4=ERC721_WITH_CRITERIA, 5=ERC1155_WITH_CRITERIA"
      t.integer "consideration_item_type", comment: "Seaport ItemType for consideration items: 0=NATIVE(ETH/MATIC), 1=ERC20, 2=ERC721, 3=ERC1155, 4=ERC721_WITH_CRITERIA, 5=ERC1155_WITH_CRITERIA"
      t.jsonb "offchain_status_metadata", default: {}, null: false
      t.jsonb "metadata", default: {}, null: false
      t.index ["consideration_item_id"], name: "index_trading_orders_on_consideration_item_id"
      t.index ["consideration_item_type"], name: "index_trading_orders_on_consideration_item_type"
      t.index ["market_id", "offchain_status", "onchain_status"], name: "index_trading_orders_on_market_and_statuses"
      t.index ["offchain_status", "onchain_status"], name: "index_trading_orders_on_offchain_and_onchain_status"
      t.index ["offchain_status"], name: "index_trading_orders_on_offchain_status"
      t.index ["offer_item_id"], name: "index_trading_orders_on_offer_item_id"
      t.index ["offer_item_type"], name: "index_trading_orders_on_offer_item_type"
      t.index ["offerer", "consideration_item_id"], name: "index_trading_orders_on_offerer_and_consideration_item_id"
      t.index ["offerer", "id"], name: "index_trading_orders_on_offerer_and_id"
      t.index ["offerer", "offer_item_id"], name: "index_trading_orders_on_offerer_and_offer_item_id"
      t.index ["onchain_status"], name: "index_trading_orders_on_onchain_status"
      t.index ["order_type"], name: "index_trading_orders_on_order_type"
    end
  
    create_table "trading_player_balance_statuses" do |t|
      t.string "player_address", null: false, comment: "player address"
      t.string "resource_type", null: false, comment: "resource type: token or currency"
      t.string "resource_id", null: false, comment: "resource ID: item_id or currency_address"
      t.decimal "required_amount", precision: 78, default: "0", null: false, comment: "total required amount"
      t.decimal "available_amount", precision: 78, default: "0", null: false, comment: "available balance"
      t.boolean "is_sufficient", default: true, null: false, comment: "balance sufficient"
      t.integer "over_matched_orders_count", default: 0, null: false, comment: "over-matched order count"
      t.datetime "last_checked_at", precision: nil, null: false, comment: "last checked at"
      t.datetime "created_at", null: false
      t.datetime "updated_at", null: false
      t.index ["is_sufficient"], name: "index_player_balance_on_sufficient"
      t.index ["last_checked_at"], name: "index_player_balance_on_checked_at"
      t.index ["player_address", "resource_type", "resource_id"], name: "index_player_balance_on_address_type_id", unique: true
      t.index ["player_address"], name: "index_player_balance_on_address"
    end
  
    create_table "trading_spread_allocations" do |t|
      t.bigint "order_fill_id", null: false
      t.string "transaction_hash", null: false
      t.integer "log_index", null: false
      t.string "market_id", null: false
      t.string "buyer_address", null: false
      t.string "seller_address", null: false
      t.string "token_address", null: false
      t.decimal "total_spread", precision: 78, null: false
      t.decimal "platform_amount", precision: 78, null: false
      t.decimal "royalty_amount", precision: 78, null: false
      t.decimal "buyer_rebate_amount", precision: 78, null: false
      t.decimal "seller_bonus_amount", precision: 78, null: false
      t.jsonb "distribution_config", default: {}
      t.string "buyer_redeem_status", default: "pending", null: false
      t.datetime "buyer_redeemed_at"
      t.string "buyer_redeem_tx_hash"
      t.string "seller_redeem_status", default: "pending", null: false
      t.datetime "seller_redeemed_at"
      t.string "seller_redeem_tx_hash"
      t.datetime "created_at", null: false
      t.datetime "updated_at", null: false
      t.index ["buyer_address", "buyer_redeem_status"], name: "idx_trading_spread_allocations_buyer_status"
      t.index ["market_id"], name: "index_trading_spread_allocations_on_market_id"
      t.index ["order_fill_id"], name: "index_trading_spread_allocations_on_order_fill_id"
      t.index ["seller_address", "seller_redeem_status"], name: "idx_trading_spread_allocations_seller_status"
      t.index ["transaction_hash", "log_index"], name: "idx_trading_spread_allocations_tx_log", unique: true
    end
  
    create_table "trading_unmatched_order_events" do |t|
      t.string "order_hash"
      t.string "event_name"
      t.string "transaction_hash"
      t.integer "log_index"
      t.integer "block_number"
      t.integer "block_timestamp"
      t.jsonb "event_data", default: {}
      t.datetime "created_at", null: false
      t.datetime "updated_at", null: false
      t.index ["order_hash"], name: "index_trading_unmatched_order_events_on_order_hash"
      t.index ["transaction_hash"], name: "index_trading_unmatched_order_events_on_transaction_hash"
    end
  
    add_foreign_key "accounts_user_favorite_items", "accounts_users", column: "user_id"
    add_foreign_key "accounts_user_messages", "accounts_users", column: "user_id"
    add_foreign_key "accounts_user_preferences", "accounts_users", column: "user_id"
    add_foreign_key "catalog_item_translations", "catalog_items", column: "item_id", primary_key: "item_id", on_delete: :cascade
    add_foreign_key "catalog_recipe_materials", "catalog_items", column: "item_id", primary_key: "item_id", on_delete: :cascade
    add_foreign_key "catalog_recipe_materials", "catalog_recipes", column: "recipe_id", primary_key: "recipe_id", on_delete: :cascade
    add_foreign_key "catalog_recipe_products", "catalog_items", column: "item_id", primary_key: "item_id", on_delete: :cascade
    add_foreign_key "catalog_recipe_products", "catalog_recipes", column: "recipe_id", primary_key: "recipe_id", on_delete: :cascade
    add_foreign_key "catalog_recipe_translations", "catalog_recipes", column: "recipe_id", primary_key: "recipe_id", on_delete: :cascade
    add_foreign_key "onchain_log_consumptions", "onchain_raw_logs", column: "raw_log_id"
    add_foreign_key "trading_order_fills", "trading_order_events", column: "event_id", name: "fk_trading_order_fills_event"
    add_foreign_key "trading_order_fills", "trading_order_events", column: "matched_event_id", name: "fk_trading_order_fills_matched_event"
    add_foreign_key "trading_order_status_logs", "trading_orders", column: "order_id"
    add_foreign_key "trading_spread_allocations", "trading_order_fills", column: "order_fill_id"
  end
end
