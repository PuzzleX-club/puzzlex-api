module Orders
  class OrderHelper
    # 计算未填充数量
    def self.calculate_unfill_amount(order_id)
      Rails.logger.warn "[OrderHelper] ⚠️ Deprecated: calculate_unfill_amount(order_id) 请改用 calculate_unfill_amount_from_order(order)"
      order = Trading::Order.find_by(id: order_id)
      calculate_unfill_amount_from_order(order)
    end

    def self.calculate_unfill_amount_from_order(order)
      return nil unless order

      # 获取订单的开始量和结束量
      # 判断订单方向，选择相应的开始量和结束量
      if order.order_direction == "Offer"
        item_start_amount = order.consideration_start_amount.to_i
        item_end_amount = order.consideration_end_amount.to_i
      elsif order.order_direction == "List"
        item_start_amount = order.offer_start_amount.to_i
        item_end_amount = order.offer_end_amount.to_i
      else
        return nil # 如果方向不是 Offer 或 List，则返回 nil
      end

      # 计算时间进度
      time_progress = calculate_time_progress(order)

      # 计算填充进度
      fill_progress = calculate_fill_progress(order)

      # 通过时间进度插值计算订单的总可成交量
      total_possible_amount = item_start_amount + (item_end_amount - item_start_amount) * time_progress

      # 计算未填充的比例
      unfilled_amount = total_possible_amount * (1 - fill_progress)

      # 返回未填充的数量
      unfilled_amount.to_i
    end

    def self.calculate_total_amount(order_id)
      Rails.logger.warn "[OrderHelper] ⚠️ Deprecated: calculate_total_amount(order_id) 请改用 calculate_total_amount_from_order(order)"
      order = Trading::Order.find_by(id: order_id)
      calculate_total_amount_from_order(order)
    end

    def self.calculate_total_amount_from_order(order)
      return nil unless order

      # ✅ 根据订单方向选择正确的字段
      if order.order_direction == "Offer"
        item_start_amount = order.consideration_start_amount.to_i
        item_end_amount = order.consideration_end_amount.to_i
      elsif order.order_direction == "List"
        item_start_amount = order.offer_start_amount.to_i
        item_end_amount = order.offer_end_amount.to_i
      else
        return nil
      end

      # 计算时间进度
      time_progress = calculate_time_progress(order)

      # 计算填充进度
      fill_progress = calculate_fill_progress(order)

      # 通过时间进度插值计算订单的总可成交量
      total_possible_amount = item_start_amount + (item_end_amount - item_start_amount) * time_progress

      # 返回订单的总可成交量
      total_possible_amount.to_i
    end

    # 根据时间插值计算当前订单价格
    # 例如：订单从start_price到end_price，线性变化，按time_progress得出当前价格
    def self.calculate_price_in_progress(order_id)
      Rails.logger.warn "[OrderHelper] ⚠️ Deprecated: calculate_price_in_progress(order_id) 请改用 calculate_price_in_progress_from_order(order)"
      order = Trading::Order.find_by(id: order_id)
      calculate_price_in_progress_from_order(order)
    end

    def self.calculate_price_in_progress_from_order(order)
      return nil unless order
      # 拿到订单的开始价、结束价
      start_price = order.start_price.to_f
      end_price   = order.end_price.to_f

      # 计算时间进度（0~1）
      time_progress = calculate_time_progress(order)

      # 做线性插值： current_price = start_price + (end_price - start_price)*time_progress
      current_price = start_price + (end_price - start_price) * time_progress

      current_price
    end

    # 根据订单的开始和结束时间计算时间进度
    def self.calculate_time_progress(order)
      start_time = order.start_time.to_i
      end_time = order.end_time.to_i
      current_time = Time.current.to_i
      # puts "[DEBUG] start_t=#{start_time}, end_t=#{end_time}, now_t=#{current_time}"

      time_range = end_time - start_time
      if time_range <= 0
        return 0.0 # 无效时间范围
      end

      time_progress = (current_time - start_time).to_f / time_range.to_f
      time_progress.clamp(0.0, 1.0) # 保证进度在0到1之间
      time_progress
    end

    # 计算填充进度 (使用 total_filled 和 total_size，即seaport合约的分数)
    def self.calculate_fill_progress(order)
      # 获取 Seaport 合约中的 total_filled 和 total_size
      total_filled = order.total_filled.to_i
      total_size = order.total_size.to_i

      # 如果 total_size <= 0，直接设定填充进度为 0 或根据业务需求处理
      return 0.0 if total_size <= 0

      # 计算填充进度
      fill_progress = total_filled.to_f / total_size.to_f
      fill_progress.clamp(0.0, 1.0) # 保证进度在0到1之间
      fill_progress
    end

    # 计算所有 fill 中的实际成交数量
    def self.calculate_total_filled(order_id)
      # 查询该订单的 fill 记录，获取所有的填充数量
      fills = Trading::OrderFill.where(order_id: order_id)

      # 计算所有成交的数量
      total_filled_amount = fills.sum(:filled_amount).to_i

      # 返回实际成交的数量
      total_filled_amount
    end

    #计算所有 fill 中 price_distribution 的代币和
    def self.calculate_filled_amt(order_id)
      fills = Trading::OrderFill.where(order_id: order_id)
      total_amt = 0.0

      fills.each do |fill|
        # 假设 price_distribution 是个 Array，里头每个元素包含 "total_amount" 字段
        distribution_array = fill.price_distribution

        # 如果不是数组，或数组元素数量不为1，直接返回-1
        unless distribution_array.is_a?(Array) && distribution_array.size == 1
          return -1
        end

        # 取唯一元素做计算
        dist = distribution_array.first
        total_amt += dist["total_amount"].to_f
      end

      total_amt
    end

    def self.parse_onchain_status(order)
      case order.onchain_status
      when "pending", 0 then 0
      when "validated", 1 then 1
      when "partially_filled", 2 then 2
      when "filled", 3 then 3
      when "cancelled", 4 then 4
      else 9 # unknown
      end
    end

    def self.parse_order_status(order)
      parse_onchain_status(order)
    end
  end
end
