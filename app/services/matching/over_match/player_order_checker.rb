# frozen_string_literal: true

class Matching::OverMatch::PlayerOrderChecker
  def initialize(active_sell_orders_resolver:, active_buy_orders_resolver:, token_id_resolver:,
                 currency_address_resolver:, token_balance_checker:, currency_balance_checker:)
    @active_sell_orders_resolver = active_sell_orders_resolver
    @active_buy_orders_resolver = active_buy_orders_resolver
    @token_id_resolver = token_id_resolver
    @currency_address_resolver = currency_address_resolver
    @token_balance_checker = token_balance_checker
    @currency_balance_checker = currency_balance_checker
  end

  def check_player_orders(player_address)
    Rails.logger.info "[OverMatch] 开始检测玩家 #{player_address} 的订单余额匹配情况"

    token_results = check_token_balances(player_address)
    currency_results = check_currency_balances(player_address)

    results = {
      player_address: player_address,
      checked_at: Time.current,
      token_checks: token_results,
      currency_checks: currency_results,
      total_over_matched: (token_results + currency_results).sum { |r| r[:over_matched_count] },
      total_restored: (token_results + currency_results).sum { |r| r[:restored_count] }
    }

    Rails.logger.info "[OverMatch] 检测完成：#{results[:total_over_matched]} 个订单被标记为超匹配，#{results[:total_restored]} 个订单已恢复"
    results
  end

  def check_token_balances(player_address)
    @active_sell_orders_resolver.call(player_address)
      .group_by { |order| @token_id_resolver.call(order) }
      .each_with_object([]) do |(token_id, orders), results|
        next if token_id.blank?

        results << @token_balance_checker.call(player_address, token_id, orders)
      end
  end

  def check_currency_balances(player_address)
    @active_buy_orders_resolver.call(player_address)
      .group_by { |order| @currency_address_resolver.call(order) }
      .each_with_object([]) do |(currency_address, orders), results|
        next if currency_address.blank?

        results << @currency_balance_checker.call(player_address, currency_address, orders)
      end
  end
end
