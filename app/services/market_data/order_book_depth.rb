class MarketData::OrderBookDepth
  def initialize(market_id, limit, validate_criteria: true)
    @market_id = market_id
    @limit = limit
    @validate_criteria = validate_criteria
  end

  def call
    Rails.logger.info "[OrderBookDepth] 开始查询市场 #{@market_id} 的深度数据"
    
    # 1) 获取"未完成"且链下状态正常的订单
    open_orders = Trading::Order.where(
      market_id: @market_id,
      onchain_status: %w[pending validated partially_filled],
      offchain_status: ['active', 'matching']  # 包含matching状态，保证流动性
    ).to_a  # 转数组以便内存处理
    
    Rails.logger.info "[OrderBookDepth] 找到 #{open_orders.size} 个订单 (market_id=#{@market_id}, status=pending/validated/partially_filled, offchain_status=active/matching)"

    # 2) 验证订单的criteria有效性
    if @validate_criteria
      Rails.logger.info "[OrderBookDepth] 开始验证#{open_orders.size}个订单的criteria有效性"
      
      valid_orders = []
      invalid_orders_count = 0
      
      open_orders.each do |order|
        if criteria_valid?(order)
          valid_orders << order
        else
          invalid_orders_count += 1
          # 🔍 添加详细的过滤日志
          criteria_hash = case order.order_direction
                         when 'Offer'
                           order.consideration_identifier
                         when 'List'
                           order.offer_identifier
                         else
                           nil
                         end
          Rails.logger.warn "[OrderBookDepth] 订单 #{order.order_hash} 的criteria无效，已排除"
          Rails.logger.warn "[OrderBookDepth]   - order_direction: #{order.order_direction}"
          Rails.logger.warn "[OrderBookDepth]   - criteria_hash: #{criteria_hash}"
          Rails.logger.warn "[OrderBookDepth]   - offer_identifier: #{order.offer_identifier}"
          Rails.logger.warn "[OrderBookDepth]   - consideration_identifier: #{order.consideration_identifier}"
        end
      end
      
      if invalid_orders_count > 0
        Rails.logger.warn "[OrderBookDepth] #{invalid_orders_count}/#{open_orders.size} 个订单因criteria无效被排除"
      else
        Rails.logger.info "[OrderBookDepth] 所有订单criteria验证通过"
      end
    else
      Rails.logger.debug "[OrderBookDepth] 跳过criteria验证"
      valid_orders = open_orders
    end

    # 3) 按 order_direction 拆分已验证的订单
    #   假设 'Offer' => 买单, 'List' => 卖单 (根据你当前逻辑)
    bid_orders = valid_orders.select { |o| o.order_direction == 'Offer' }
    ask_orders = valid_orders.select { |o| o.order_direction == 'List' }

    # 4) 对买单/卖单分别：
    #    (a) 计算 current_price + unfilled_qty
    #    (b) 排序
    #    (c) 截取@limit
    bid_list = bid_orders.map do |o|
      current_price = Orders::OrderHelper.calculate_price_in_progress_from_order(o)  # 保持Wei格式
      unfilled_qty  = Orders::OrderHelper.calculate_unfill_amount_from_order(o)
      # 统一转换为字符串格式，保持前后端一致
      [current_price.to_i.to_s, unfilled_qty.to_s, o.order_hash, o.consideration_identifier, o.created_at.to_i.to_s]
    end.sort_by { |price, _, _, _,created_at| [-price.to_i, -created_at.to_i]  } # 买单 => 降序，按Wei值排序
                         .first(@limit)

    ask_list = ask_orders.map do |o|
      current_price = Orders::OrderHelper.calculate_price_in_progress_from_order(o)  # 保持Wei格式
      unfilled_qty  = Orders::OrderHelper.calculate_unfill_amount_from_order(o)
      # 统一转换为字符串格式，保持前后端一致
      [current_price.to_i.to_s, unfilled_qty.to_s, o.order_hash, o.offer_identifier, o.created_at.to_i.to_s]
    end.sort_by { |price, _, _, _,created_at| [price.to_i, created_at.to_i] }  # 卖单 => 升序，按Wei值排序
                         .first(@limit)

    # 5) 返回结构
    {
      market_id: @market_id,
      levels: @limit,
      bids: bid_list,  # => [[price, qty, order_hash], ...]
      asks: ask_list
    }
  end

  private

  # 验证订单的criteria是否有效
  def criteria_valid?(order)
    # 获取订单的criteria（根据订单方向）
    criteria_hash = case order.order_direction
                   when 'Offer'
                     order.consideration_identifier
                   when 'List'
                     order.offer_identifier
                   else
                     nil
                   end
    
    # 如果不是criteria格式（非0x开头的66位hash），直接认为有效
    return true unless criteria_hash&.start_with?('0x') && criteria_hash&.length == 66
    
    # 检查criteria对应的根节点是否存在且有效
    # 首先尝试查找最新的活跃根节点
    root_record = Merkle::TreeRoot.find_latest_active_by_root_hash(criteria_hash)
    
    if root_record.nil?
      # 如果没有活跃的，再检查是否存在任何记录（用于日志记录）
      any_record = Merkle::TreeRoot.find_by_root_hash(criteria_hash)
      if any_record.nil?
      Rails.logger.debug "[OrderBookDepth] Criteria #{criteria_hash} 无对应根节点记录"
      else
        Rails.logger.debug "[OrderBookDepth] Criteria #{criteria_hash} 对应的Merkle树已被删除或过期"
    end
      return false
    end
    
    # 检查根节点是否即将过期（距离过期小于1小时则警告但仍允许）
    if root_record.expires_at && root_record.expires_at < 1.hour.from_now
      Rails.logger.warn "[OrderBookDepth] Criteria #{criteria_hash} 即将在 #{root_record.expires_at} 过期"
    end
    
    true
  rescue => e
    Rails.logger.error "[OrderBookDepth] 验证criteria #{criteria_hash} 时出错: #{e.message}"
    # 出错时保守处理，认为有效以避免影响正常订单
    true
  end 
end
