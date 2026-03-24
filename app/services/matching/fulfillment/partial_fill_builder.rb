# frozen_string_literal: true

class Matching::Fulfillment::PartialFillBuilder
  def initialize(numeric_parser:)
    @numeric_parser = numeric_parser
  end

  def needs_partial_fill?(match_orders)
    return false if match_orders.blank?

    match_orders.any? do |match|
      next false unless match

      match['partial_match'] == true ||
        (match['bid_filled'] && match['bid_total'] && match['bid_filled'] < match['bid_total'])
    end
  end

  def calculate_total_ask_qty(ask_order_hashes)
    return 0 if ask_order_hashes.blank?

    ask_order_hashes.sum do |order_hash|
      order = Trading::Order.find_by(order_hash: order_hash)
      next 0 unless order

      extract_order_quantity(order)
    end
  end

  def extract_order_quantity(order)
    return 0 unless order && order.parameters

    if order.order_direction == 'List'
      offer_items = order.parameters['offer'] || []
      return 0 if offer_items.empty?

      offer_items.first['startAmount'].to_i
    else
      consideration_items = order.parameters['consideration'] || []
      return 0 if consideration_items.empty?

      consideration_items.first['startAmount'].to_i
    end
  end

  def generate_partial_fill_options(match_orders)
    return [] if match_orders.blank?

    has_partial_fill = match_orders.any? do |match|
      next false unless match && match['bid'] && match['ask']

      bid_total = match['bid_total'] || match['bid'][1].to_i
      bid_filled = match['bid_filled'] || bid_total
      bid_filled < bid_total || match['partial_match'] == true
    end

    unless has_partial_fill
      Rails.logger.info "[PartialFill] 所有订单都是完全撮合，不需要生成部分撮合参数"
      return []
    end

    Rails.logger.info "[PartialFill] 检测到部分撮合，为所有订单生成numerator/denominator参数"

    options = []
    all_orders = []

    match_orders.each_with_index do |match, match_index|
      next unless match && match['bid'] && match['ask']

      bid_hash = match['bid'][2]
      bid_total = match['bid_total'] || match['bid'][1].to_i
      bid_filled = match['bid_filled'] || bid_total
      ask_order_hashes = match['ask'][:current_orders] || []
      current_orders_in_group = [bid_hash] + ask_order_hashes

      bid_order = Trading::Order.find_by(order_hash: bid_hash)
      ask_orders = Trading::Order.where(order_hash: ask_order_hashes).to_a

      Rails.logger.info "[PartialFill] 匹配组#{match_index}: 买单实际成交#{bid_filled}/#{bid_total}"

      bid_index = all_orders.length
      if bid_order && bid_order.total_size > 0
        Rails.logger.info "[PartialFill] 买单续撮：已成交#{bid_order.total_filled}，本次增量#{bid_filled}，订单总量#{bid_order.total_size}"
        options << {
          orderIndex: bid_index,
          numerator: bid_filled.to_i,
          denominator: bid_order.total_size.to_i
        }
      else
        if bid_filled < bid_total
          Rails.logger.info "[PartialFill] 买单部分成交：#{bid_filled}/#{bid_total}"
        else
          Rails.logger.info "[PartialFill] 买单完全成交：#{bid_filled}/#{bid_total}"
        end
        options << {
          orderIndex: bid_index,
          numerator: bid_filled.to_i,
          denominator: bid_total.to_i
        }
      end

      ask_fill_lookup = (match['ask_fills'] || []).each_with_object({}) do |fill, memo|
        memo[fill['order_hash'].to_s] = to_numeric(fill['filled_qty'], "ask_fills.#{fill['order_hash']}.filled_qty")
      end

      ask_orders.each_with_index do |ask_order, ask_idx|
        ask_index = all_orders.length + 1 + ask_idx
        ask_qty = extract_order_quantity(ask_order)
        ask_filled = ask_fill_lookup[ask_order.order_hash] || ask_qty

        if ask_order.total_size > 0
          Rails.logger.info "[PartialFill] 卖单续撮：已成交#{ask_order.total_filled}，本次增量#{ask_filled}，订单总量#{ask_order.total_size}"
          options << {
            orderIndex: ask_index,
            numerator: ask_filled.to_i,
            denominator: ask_order.total_size.to_i
          }
        else
          if ask_filled < ask_qty
            Rails.logger.info "[PartialFill] 卖单部分成交：#{ask_filled}/#{ask_qty}"
          else
            Rails.logger.info "[PartialFill] 卖单完全成交：#{ask_filled}/#{ask_qty}"
          end
          options << {
            orderIndex: ask_index,
            numerator: ask_filled.to_i,
            denominator: ask_qty.to_i
          }
        end
      end

      all_orders.concat(current_orders_in_group)
    end

    Rails.logger.info "[PartialFill] 生成了 #{options.size} 个部分撮合参数"
    options.each_with_index do |option, index|
      Rails.logger.info "[PartialFill]   参数#{index}: orderIndex=#{option[:orderIndex]}, numerator=#{option[:numerator]}, denominator=#{option[:denominator]}"
    end

    options
  end

  def build_ask_fill_breakdown(current_order_hashes, asks, total_filled_qty)
    return [] if current_order_hashes.blank? || asks.blank?

    qty_by_hash = asks.each_with_object({}) do |ask, memo|
      next unless ask.is_a?(Array) && ask.size >= 3
      memo[ask[2].to_s] = to_numeric(ask[1], "ask.qty.#{ask[2]}")
    end

    remaining = to_numeric(total_filled_qty, 'total_filled_qty')
    fills = []

    current_order_hashes.each do |order_hash|
      ask_hash = order_hash.to_s
      ask_qty = qty_by_hash[ask_hash]
      next unless ask_qty

      filled = [ask_qty, remaining].min
      filled = 0 if filled.negative?

      fills << {
        'order_hash' => ask_hash,
        'total_qty' => ask_qty,
        'filled_qty' => filled
      }

      remaining -= filled
      break if remaining <= 0
    end

    fills
  end

  private

  def to_numeric(value, field_desc)
    @numeric_parser.call(value, field_desc)
  end
end
