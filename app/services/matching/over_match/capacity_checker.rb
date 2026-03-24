# frozen_string_literal: true

class Matching::OverMatch::CapacityChecker
  def initialize(currency_address_resolver:, token_id_resolver:, token_amount_resolver:,
                 currency_amount_resolver:, currency_balance_resolver:, currency_allowance_resolver:,
                 token_approval_resolver:, token_balance_resolver:, seaport_contract_address_provider:)
    @currency_address_resolver = currency_address_resolver
    @token_id_resolver = token_id_resolver
    @token_amount_resolver = token_amount_resolver
    @currency_amount_resolver = currency_amount_resolver
    @currency_balance_resolver = currency_balance_resolver
    @currency_allowance_resolver = currency_allowance_resolver
    @token_approval_resolver = token_approval_resolver
    @token_balance_resolver = token_balance_resolver
    @seaport_contract_address_provider = seaport_contract_address_provider
  end

  def check_order_balance_and_approval(order)
    return { sufficient: true, reason: nil } unless order

    if order.order_direction == 'Offer'
      check_buy_order_capacity(order)
    elsif order.order_direction == 'List'
      check_sell_order_capacity(order)
    else
      { sufficient: true, reason: nil }
    end
  end

  def check_buy_order_capacity(order)
    currency_address = @currency_address_resolver.call(order)
    remaining_qty = Orders::OrderHelper.calculate_unfill_amount_from_order(order)
    if remaining_qty.nil?
      remaining_qty = @token_amount_resolver.call(order)
      Rails.logger.info "[OverMatch] ⚠️ 未成交数量为空，降级使用订单数量: #{remaining_qty}"
    end

    current_price = Orders::OrderHelper.calculate_price_in_progress_from_order(order)
    if current_price.nil?
      current_price = order.start_price
      Rails.logger.info "[OverMatch] ⚠️ 当前价为空，降级使用 start_price: #{current_price}"
    end

    required_amount = (remaining_qty.to_f * current_price.to_f).to_i
    allowance_result = @currency_allowance_resolver.call(
      order.offerer,
      currency_address,
      @seaport_contract_address_provider.call
    )
    if allowance_result[:error]
      Rails.logger.warn "[OverMatch] 货币授权查询失败，跳过检测: order=#{order.order_hash}, error=#{allowance_result[:error]}"
      return { sufficient: true, reason: 'balance_check_failed', error: allowance_result[:error], required: required_amount, available: nil }
    end

    balance_result = @currency_balance_resolver.call(order.offerer, currency_address)
    if balance_result[:error]
      Rails.logger.warn "[OverMatch] 货币余额查询失败，跳过检测: order=#{order.order_hash}, error=#{balance_result[:error]}"
      return { sufficient: true, reason: 'balance_check_failed', error: balance_result[:error], required: required_amount, available: nil }
    end

    allowance_amount = allowance_result[:allowance]
    available_balance = balance_result[:balance]
    available_amount = [available_balance, allowance_amount].min

    if allowance_amount < required_amount
      return {
        sufficient: false,
        reason: 'erc20_allowance_insufficient',
        available: available_amount,
        required: required_amount
      }
    end

    {
      sufficient: available_amount >= required_amount,
      reason: available_amount >= required_amount ? nil : 'currency_insufficient',
      available: available_amount,
      required: required_amount
    }
  end

  def check_sell_order_capacity(order)
    token_id = @token_id_resolver.call(order)
    return { sufficient: true, reason: nil } if token_id.blank?

    remaining_qty = Orders::OrderHelper.calculate_unfill_amount_from_order(order)
    if remaining_qty.nil?
      remaining_qty = @token_amount_resolver.call(order)
      Rails.logger.info "[OverMatch] ⚠️ 未成交数量为空，降级使用订单数量: #{remaining_qty}"
    end

    approval_result = @token_approval_resolver.call(order.offerer, @seaport_contract_address_provider.call)
    if approval_result[:error]
      Rails.logger.warn "[OverMatch] ERC1155授权查询失败，跳过检测: order=#{order.order_hash}, error=#{approval_result[:error]}"
      return { sufficient: true, reason: 'balance_check_failed', error: approval_result[:error], required: remaining_qty, available: nil }
    end

    balance_result = @token_balance_resolver.call(order.offerer, token_id)
    if balance_result[:error]
      Rails.logger.warn "[OverMatch] Token余额查询失败，跳过检测: order=#{order.order_hash}, error=#{balance_result[:error]}"
      return { sufficient: true, reason: 'balance_check_failed', error: balance_result[:error], required: remaining_qty, available: nil }
    end

    approved = approval_result[:approved]
    available_balance = balance_result[:balance]
    available_amount = approved ? available_balance : 0

    unless approved
      return {
        sufficient: false,
        reason: 'erc1155_approval_missing',
        available: available_amount,
        required: remaining_qty
      }
    end

    {
      sufficient: available_amount >= remaining_qty.to_i,
      reason: available_amount >= remaining_qty.to_i ? nil : 'token_insufficient',
      available: available_amount,
      required: remaining_qty
    }
  end
end
