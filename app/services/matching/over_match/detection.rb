# frozen_string_literal: true

class Matching::OverMatch::Detection
  class << self
    def check_order_balance_and_approval(order)
      capacity_checker.check_order_balance_and_approval(order)
    end

    def check_player_orders(player_address)
      player_order_checker.check_player_orders(player_address)
    end

    def check_token_balances(player_address)
      player_order_checker.check_token_balances(player_address)
    end

    def check_currency_balances(player_address)
      player_order_checker.check_currency_balances(player_address)
    end

    def check_token_id_balance(player_address, token_id, orders)
      resource_balance_checker.check_token_id_balance(player_address, token_id, orders)
    end

    def check_currency_balance(player_address, currency_address, orders)
      resource_balance_checker.check_currency_balance(player_address, currency_address, orders)
    end

    def get_active_sell_orders(player_address)
      Trading::Order.where(
        offerer: player_address,
        order_direction: 'List',
        onchain_status: %w[pending validated partially_filled],
        offchain_status: %w[active over_matched]
      )
    end

    def get_active_buy_orders(player_address)
      Trading::Order.where(
        offerer: player_address,
        order_direction: 'Offer',
        onchain_status: %w[pending validated partially_filled],
        offchain_status: %w[active over_matched]
      )
    end

    def get_order_token_id(order)
      order_resource_helper.get_order_token_id(order)
    end

    def get_order_currency_address(order)
      order_resource_helper.get_order_currency_address(order)
    end

    def calculate_order_token_amount(order)
      order_resource_helper.calculate_order_token_amount(order)
    end

    def calculate_order_currency_amount(order)
      order_resource_helper.calculate_order_currency_amount(order)
    end

    def get_player_token_balance(player_address, token_id)
      balance_gateway.get_player_token_balance(player_address, token_id)
    end

    def get_indexer_token_balance(player_address, token_id)
      balance_gateway.get_indexer_token_balance(player_address, token_id)
    end

    def get_player_token_approval(player_address, operator_address)
      balance_gateway.get_player_token_approval(player_address, operator_address)
    end

    def get_player_currency_balance(player_address, currency_address)
      balance_gateway.get_player_currency_balance(player_address, currency_address)
    end

    def get_player_currency_allowance(player_address, currency_address, spender_address)
      balance_gateway.get_player_currency_allowance(player_address, currency_address, spender_address)
    end

    def backup_and_set_over_matched(order, reason, resource_id)
      status_reconciler.backup_and_set_over_matched(order, reason, resource_id)
    end

    def restore_order_from_backup(order)
      status_reconciler.restore_order_from_backup(order)
    end

    def seaport_contract_address
      balance_gateway.seaport_contract_address
    end

    def sort_orders_by_priority(orders, side)
      order_resource_helper.sort_orders_by_priority(orders, side)
    end

    def build_skipped_balance_result(resource_type, resource_id, orders_count, error)
      status_reconciler.build_skipped_balance_result(resource_type, resource_id, orders_count, error)
    end

    private

    def order_resource_helper
      @order_resource_helper ||= Matching::OverMatch::OrderResourceHelper.new
    end

    def balance_gateway
      @balance_gateway ||= Matching::OverMatch::BalanceGateway.new
    end

    def status_reconciler
      @status_reconciler ||= Matching::OverMatch::StatusReconciler.new
    end

    def resource_balance_checker
      Matching::OverMatch::ResourceBalanceChecker.new(
        token_approval_resolver: ->(*args) { get_player_token_approval(*args) },
        token_balance_resolver: ->(*args) { get_player_token_balance(*args) },
        currency_balance_resolver: ->(*args) { get_player_currency_balance(*args) },
        currency_allowance_resolver: ->(*args) { get_player_currency_allowance(*args) },
        order_sorter: ->(*args) { sort_orders_by_priority(*args) },
        token_amount_resolver: ->(*args) { calculate_order_token_amount(*args) },
        currency_amount_resolver: ->(*args) { calculate_order_currency_amount(*args) },
        backup_handler: ->(*args) { backup_and_set_over_matched(*args) },
        restore_handler: ->(*args) { restore_order_from_backup(*args) },
        skipped_result_builder: ->(*args) { build_skipped_balance_result(*args) },
        seaport_contract_address_provider: -> { seaport_contract_address }
      )
    end

    def capacity_checker
      Matching::OverMatch::CapacityChecker.new(
        currency_address_resolver: ->(*args) { get_order_currency_address(*args) },
        token_id_resolver: ->(*args) { get_order_token_id(*args) },
        token_amount_resolver: ->(*args) { calculate_order_token_amount(*args) },
        currency_amount_resolver: ->(*args) { calculate_order_currency_amount(*args) },
        currency_balance_resolver: ->(*args) { get_player_currency_balance(*args) },
        currency_allowance_resolver: ->(*args) { get_player_currency_allowance(*args) },
        token_approval_resolver: ->(*args) { get_player_token_approval(*args) },
        token_balance_resolver: ->(*args) { get_player_token_balance(*args) },
        seaport_contract_address_provider: -> { seaport_contract_address }
      )
    end

    def player_order_checker
      Matching::OverMatch::PlayerOrderChecker.new(
        active_sell_orders_resolver: ->(*args) { get_active_sell_orders(*args) },
        active_buy_orders_resolver: ->(*args) { get_active_buy_orders(*args) },
        token_id_resolver: ->(*args) { get_order_token_id(*args) },
        currency_address_resolver: ->(*args) { get_order_currency_address(*args) },
        token_balance_checker: ->(*args) { check_token_id_balance(*args) },
        currency_balance_checker: ->(*args) { check_currency_balance(*args) }
      )
    end
  end
end
