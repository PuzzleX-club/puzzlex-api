# frozen_string_literal: true

class Matching::OverMatch::ResourceBalanceChecker
  def initialize(token_approval_resolver:, token_balance_resolver:, currency_balance_resolver:,
                 currency_allowance_resolver:, order_sorter:, token_amount_resolver:,
                 currency_amount_resolver:, backup_handler:, restore_handler:,
                 skipped_result_builder:, seaport_contract_address_provider:)
    @token_approval_resolver = token_approval_resolver
    @token_balance_resolver = token_balance_resolver
    @currency_balance_resolver = currency_balance_resolver
    @currency_allowance_resolver = currency_allowance_resolver
    @order_sorter = order_sorter
    @token_amount_resolver = token_amount_resolver
    @currency_amount_resolver = currency_amount_resolver
    @backup_handler = backup_handler
    @restore_handler = restore_handler
    @skipped_result_builder = skipped_result_builder
    @seaport_contract_address_provider = seaport_contract_address_provider
  end

  def check_token_id_balance(player_address, token_id, orders)
    Rails.logger.debug "[OverMatch] 检测Token ID #{token_id} 的余额，订单数量: #{orders.length}"

    operator_address = @seaport_contract_address_provider.call
    approval_result = @token_approval_resolver.call(player_address, operator_address)
    if approval_result[:error]
      Rails.logger.warn "[OverMatch] ERC1155授权查询失败，跳过检测: player=#{player_address}, token_id=#{token_id}, error=#{approval_result[:error]}"
      return @skipped_result_builder.call('token', token_id, orders.length, approval_result[:error])
    end

    balance_result = @token_balance_resolver.call(player_address, token_id)
    if balance_result[:error]
      Rails.logger.warn "[OverMatch] Token余额查询失败，跳过检测: player=#{player_address}, token_id=#{token_id}, error=#{balance_result[:error]}"
      return @skipped_result_builder.call('token', token_id, orders.length, balance_result[:error])
    end

    approved = approval_result[:approved]
    available_balance = balance_result[:balance]
    effective_balance = approved ? available_balance : 0
    insufficient_reason = approved ? 'token_insufficient' : 'erc1155_approval_missing'

    sorted_orders = @order_sorter.call(orders, :sell)
    required_amount = 0
    cumulative_amount = 0
    over_matched_count = 0
    restored_count = 0

    sorted_orders.each do |order|
      order_amount = @token_amount_resolver.call(order)
      required_amount += order_amount

      if cumulative_amount + order_amount <= effective_balance
        if order.offchain_status == 'over_matched'
          @restore_handler.call(order)
          restored_count += 1
        end
        cumulative_amount += order_amount
      else
        unless order.offchain_status == 'over_matched'
          @backup_handler.call(order, insufficient_reason, token_id.to_s)
          over_matched_count += 1
        end
      end
    end

    balance_status = Trading::PlayerBalanceStatus.find_or_initialize_for_resource(
      player_address, 'token', token_id.to_s
    )
    balance_status.update_status(
      required: required_amount,
      available: effective_balance,
      over_matched_count: over_matched_count
    )

    {
      resource_type: 'token',
      resource_id: token_id.to_s,
      required_amount: required_amount,
      available_amount: effective_balance,
      is_sufficient: effective_balance >= required_amount,
      orders_count: orders.length,
      over_matched_count: over_matched_count,
      restored_count: restored_count
    }
  end

  def check_currency_balance(player_address, currency_address, orders)
    Rails.logger.debug "[OverMatch] 检测货币 #{currency_address} 的余额，订单数量: #{orders.length}"

    balance_result = @currency_balance_resolver.call(player_address, currency_address)
    if balance_result[:error]
      Rails.logger.warn "[OverMatch] 货币余额查询失败，跳过检测: player=#{player_address}, currency=#{currency_address}, error=#{balance_result[:error]}"
      return @skipped_result_builder.call('currency', currency_address, orders.length, balance_result[:error])
    end

    allowance_result = @currency_allowance_resolver.call(
      player_address,
      currency_address,
      @seaport_contract_address_provider.call
    )
    if allowance_result[:error]
      Rails.logger.warn "[OverMatch] 货币授权查询失败，跳过检测: player=#{player_address}, currency=#{currency_address}, error=#{allowance_result[:error]}"
      return @skipped_result_builder.call('currency', currency_address, orders.length, allowance_result[:error])
    end

    available_balance = balance_result[:balance]
    allowance_amount = allowance_result[:allowance]
    available_amount = [available_balance, allowance_amount].min

    sorted_orders = @order_sorter.call(orders, :buy)
    required_amount = 0
    cumulative_amount = 0
    over_matched_count = 0
    restored_count = 0

    sorted_orders.each do |order|
      order_amount = @currency_amount_resolver.call(order)
      required_amount += order_amount

      if cumulative_amount + order_amount <= available_amount
        if order.offchain_status == 'over_matched'
          @restore_handler.call(order)
          restored_count += 1
        end
        cumulative_amount += order_amount
      else
        unless order.offchain_status == 'over_matched'
          reason = allowance_amount < (cumulative_amount + order_amount) ? 'erc20_allowance_insufficient' : 'currency_insufficient'
          @backup_handler.call(order, reason, currency_address)
          over_matched_count += 1
        end
      end
    end

    balance_status = Trading::PlayerBalanceStatus.find_or_initialize_for_resource(
      player_address, 'currency', currency_address
    )
    balance_status.update_status(
      required: required_amount,
      available: available_amount,
      over_matched_count: over_matched_count
    )

    {
      resource_type: 'currency',
      resource_id: currency_address,
      required_amount: required_amount,
      available_amount: available_amount,
      is_sufficient: available_amount >= required_amount,
      orders_count: orders.length,
      over_matched_count: over_matched_count,
      restored_count: restored_count
    }
  end
end
