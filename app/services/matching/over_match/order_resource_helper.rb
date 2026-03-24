# frozen_string_literal: true

class Matching::OverMatch::OrderResourceHelper
  def get_order_token_id(order)
    case order.order_direction
    when 'List'
      identifier = order.offer_identifier
    when 'Offer'
      identifier = order.consideration_identifier
    else
      return nil
    end

    if identifier.is_a?(String) && identifier.start_with?('0x') && identifier.length == 66
      Rails.logger.debug "[OverMatch] 跳过 criteria 格式的订单检测: #{identifier}"
      return nil
    end

    identifier
  end

  def get_order_currency_address(order)
    case order.order_direction
    when 'List'
      order.consideration_token
    when 'Offer'
      order.offer_token
    else
      nil
    end
  end

  def calculate_order_token_amount(order)
    case order.order_direction
    when 'List'
      order.offer_start_amount || 0
    when 'Offer'
      order.consideration_start_amount || 0
    else
      0
    end
  end

  def calculate_order_currency_amount(order)
    case order.order_direction
    when 'List'
      order.consideration_start_amount || 0
    when 'Offer'
      order.offer_start_amount || 0
    else
      0
    end
  end

  def sort_orders_by_priority(orders, side)
    orders.sort_by do |order|
      current_price = Orders::OrderHelper.calculate_price_in_progress_from_order(order)
      current_price = order.start_price if current_price.nil?
      price = current_price.to_f

      price_key = side == :buy ? -price : price
      time_key = -order.created_at.to_i
      [price_key, time_key]
    end
  end
end
