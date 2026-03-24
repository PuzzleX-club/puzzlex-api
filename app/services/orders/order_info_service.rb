# app/services/order_info_service.rb
class Orders::OrderInfoService
  # 接收一个 Trading::Order 实例，返回符合前端 OrderInfo 的哈希
  # todo:解析过程需要更新，目前前端尚无法实现uid的区分，需要在更新前端，同时添加jwt功能
  # 该方法已启用
  def self.build_order_info(order)
    {
      order_id:        order.id,          # bigInt.BigInteger => Rails 会返回整数，前端可转 bigInt
      market_id:       get_market_id(order),
      uid:             get_user_id(order),
      side:            parse_side(order),
      order_type:      parse_order_type(order),
      onchain_status:  parse_onchain_status(order),
      price:           order.start_price.to_s,
      unfilled_qty:    compute_unfilled_qty(order).to_s,
      filled_qty:      compute_filled_qty(order).to_s,
      filled_amt:      compute_filled_amt(order).to_s,
      fee_rate:        (order.fee_rate || 0),
      fee:             (order.fee || 0),
      ver:             (order.ver || 1),
      created_ts:      order.created_at.to_i,
      symbol:          order.symbol || "",
      ts_str:          order.created_at.strftime("%Y-%m-%d %H:%M:%S"),
      side_str:        side_str(order),
      order_type_str:  order_type_str(order),
      onchain_status_str: onchain_status_str(order),
      price_str:       order.start_price.to_s,
      qty_str:         order.offer_start_amount.to_s
    }
  end

  private
  # ============ 以下是可能的辅助方法 ============

  def self.get_market_id(order)
    # 如果 order 里没有 market_id 字段，可取固定值或者从别的表查询
    order.market_id || 1
  end

  def self.get_user_id(order)
    # 如果 order 没有 user_id，那你可能需要在 orders 表中加字段，或用 order.offerer => uid
    # 示例：把 order.offerer 视为 address, 需要再做映射 => 暂时写0
    0
  end

  def self.parse_side(order)
    # 如果 order.order_direction == "Offer" 就认为 side=1(买)，否则2(卖)
    order.order_direction == "Offer" ? 1 : 2
  end

  def self.parse_order_type(order)
    # 如果没有明确字段，就可能 1=通配, 2=精确
    if (order.offer_identifier.present? && order.offer_identifier.start_with?("0x")) ||
      (order.consideration_identifier.present? && order.consideration_identifier.start_with?("0x"))
      1
    else
      2
    end
  end

  def self.parse_onchain_status(order)
    order.onchain_status
  end

  def self.compute_unfilled_qty(order)
    # 如果你有 total_size / total_filled => unfilled = size - filled
    order.total_size - order.total_filled
  end

  def self.compute_filled_qty(order)
    order.total_filled
  end

  def self.compute_filled_amt(order)
    # 假设 filled_amt = filled_qty * price
    order.total_filled * order.start_price
  end

  def self.side_str(order)
    # 1 => "买单", 2 => "卖单"
    parse_side(order) == 1 ? "买单" : "卖单"
  end

  def self.order_type_str(order)
    parse_order_type(order) == 1 ? "市价" : "限价"
  end

  def self.onchain_status_str(order)
    case parse_onchain_status(order)
    when "pending" then "待验证"
    when "validated" then "已验证"
    when "partially_filled" then "部分成交"
    when "filled" then "已成交"
    when "cancelled" then "已取消"
    else "未知状态"
    end
  end
end
