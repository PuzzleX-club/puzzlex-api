# 订单状态验证服务
# 在撮合流程中验证订单状态、余额等关键信息
class Matching::State::OrderStatusValidator
  
  def initialize
    @logger = Rails.logger
  end

  # 🔍 撮合前验证：过滤出真正可以撮合的订单
  def filter_valid_orders_for_matching(bids, asks)
    @logger.info "[OrderValidator] 开始验证撮合订单：#{bids.size}个买单，#{asks.size}个卖单"
    
    valid_bids = filter_valid_bid_orders(bids)
    valid_asks = filter_valid_ask_orders(asks)
    
    @logger.info "[OrderValidator] 验证完成：#{valid_bids.size}个有效买单，#{valid_asks.size}个有效卖单"
    
    {
      bids: valid_bids,
      asks: valid_asks,
      filtered_count: {
        bids: bids.size - valid_bids.size,
        asks: asks.size - valid_asks.size
      }
    }
  end

  # 🔍 验证买单有效性
  def filter_valid_bid_orders(bids)
    valid_orders = []
    
    bids.each do |bid|
      order_hash = bid[2]
      order = Trading::Order.find_by(order_hash: order_hash)
      
      if order.nil?
        @logger.warn "[OrderValidator] 买单不存在：#{order_hash}"
        next
      end
      
      # 新增：检查是否包含原生代币
      if contains_native_token?(order)
        @logger.info "[OrderValidator] 买单包含原生代币，不支持自动撮合：#{order_hash}"
        next
      end
      
      # 检查基本状态
      unless valid_basic_status?(order)
        @logger.debug "[OrderValidator] 买单状态无效：#{order_hash} (#{order.onchain_status}/#{order.offchain_status})"
        next
      end
      
      # 检查余额
      unless sufficient_currency_balance?(order)
        @logger.debug "[OrderValidator] 买单余额不足：#{order_hash}"
        mark_order_over_matched(order, 'currency_insufficient')
        next
      end
      
      valid_orders << bid
    end

    valid_orders
  end

  # 🔍 验证卖单有效性
  def filter_valid_ask_orders(asks)
    valid_orders = []

    asks.each do |ask|
      order_hash = ask[2]
      order = Trading::Order.find_by(order_hash: order_hash)

      if order.nil?
        @logger.warn "[OrderValidator] 卖单不存在：#{order_hash}"
        next
      end

      # 新增：检查是否包含原生代币
      if contains_native_token?(order)
        @logger.info "[OrderValidator] 卖单包含原生代币，不支持自动撮合：#{order_hash}"
        next
      end

      # 检查基本状态
      unless valid_basic_status?(order)
        @logger.debug "[OrderValidator] 卖单状态无效：#{order_hash} (#{order.onchain_status}/#{order.offchain_status})"
        next
      end

      # 检查token余额
      unless sufficient_token_balance?(order)
        @logger.debug "[OrderValidator] 卖单余额不足：#{order_hash}"
        mark_order_over_matched(order, 'token_insufficient')
        next
      end

      valid_orders << ask
    end
    
    valid_orders
  end

  # 🔄 撮合后更新订单状态
  def update_orders_after_matching(matched_orders)
    @logger.info "[OrderValidator] 开始更新 #{matched_orders.size} 个匹配组的订单状态"
    
    updated_count = 0
    
    matched_orders.each do |match|
      if match['side'] == 'Offer'
        # 更新买单状态
        bid_hash = match['bid'][2]
        update_order_status_to_matched(bid_hash)
        updated_count += 1
        
        # 更新卖单状态
        match['ask'][:current_orders].each do |ask_hash|
          update_order_status_to_matched(ask_hash)
          updated_count += 1
        end
      end
    end
    
    @logger.info "[OrderValidator] 状态更新完成：#{updated_count} 个订单状态已更新"
  end

  # 🔄 撮合失败后恢复订单状态
  def restore_orders_after_failed_matching(order_hashes)
    @logger.info "[OrderValidator] 撮合失败，恢复 #{order_hashes.size} 个订单状态"
    
    order_hashes.each do |order_hash|
      restore_order_status_to_active(order_hash)
    end
  end

  private

  # 检查订单基本状态
  def valid_basic_status?(order)
    # 检查链上状态
    return false unless %w[pending validated partially_filled].include?(order.onchain_status)
    
    # 检查链下状态
    return false unless order.offchain_status == 'active'
    
    # 检查订单是否过期（如果有end_time）
    if order.end_time.present? && order.end_time != Rails.application.config.x.blockchain.seaport_max_uint256
      end_time_unix = order.end_time.to_i
      if Time.current.to_i >= end_time_unix
        @logger.debug "[OrderValidator] 订单已过期：#{order.order_hash} (#{Time.at(end_time_unix)})"
        mark_order_expired(order)
        return false
      end
    end
    
    true
  end

  # 检查货币余额是否充足（买单）
  def sufficient_currency_balance?(order)
    return true unless order.order_direction == 'Offer'
    return true if skip_balance_validation?
    
    begin
      result = Matching::OverMatch::Detection.check_order_balance_and_approval(order)
      if result[:reason] == 'balance_check_failed'
        @logger.warn "[OrderValidator] 货币余额校验失败，跳过标记: #{order.order_hash}"
        return true
      end
      return true if result[:sufficient]

      if result[:reason] == 'erc20_allowance_insufficient'
        @logger.debug "[OrderValidator] ERC20授权不足：需要 #{result[:required]}，授权 #{result[:available]}"
        mark_order_over_matched(order, 'erc20_allowance_insufficient')
        return false
      end

      @logger.debug "[OrderValidator] 货币余额不足：需要 #{result[:required]}，可用 #{result[:available]}"
      false
    rescue => e
      @logger.error "[OrderValidator] 检查货币余额失败：#{e.message}"
      false
    end
  end

  # 检查token余额是否充足（卖单）
  def sufficient_token_balance?(order)
    return true unless order.order_direction == 'List'
    return true if skip_balance_validation?
    
    begin
      result = Matching::OverMatch::Detection.check_order_balance_and_approval(order)
      if result[:reason] == 'balance_check_failed'
        @logger.warn "[OrderValidator] Token余额校验失败，跳过标记: #{order.order_hash}"
        return true
      end
      return true if result[:sufficient]

      if result[:reason] == 'erc1155_approval_missing'
        @logger.debug "[OrderValidator] ERC1155授权不足"
        mark_order_over_matched(order, 'erc1155_approval_missing')
        return false
      end

      @logger.debug "[OrderValidator] Token余额不足：需要 #{result[:required]}，可用 #{result[:available]}"
      false
    rescue => e
      @logger.error "[OrderValidator] 检查Token余额失败：#{e.message}"
      false
    end
  end

  # 标记订单为超匹配状态
  def mark_order_over_matched(order, reason)
    begin
      # 根据原因确定正确的resource_id
      resource_id = case reason
      when 'currency_insufficient'
        Matching::OverMatch::Detection.get_order_currency_address(order)
      when 'token_insufficient'
        Matching::OverMatch::Detection.get_order_token_id(order)
      when 'erc20_allowance_insufficient'
        Matching::OverMatch::Detection.get_order_currency_address(order)
      when 'erc1155_approval_missing'
        Matching::OverMatch::Detection.send(:seaport_contract_address)
      else
        reason
      end

      # 确保resource_id不为空
      resource_id ||= 'unknown'

      Matching::OverMatch::Detection.send(:backup_and_set_over_matched, order, reason, resource_id)
      @logger.debug "[OrderValidator] 订单已标记为超匹配：#{order.order_hash} (#{reason}, resource_id=#{resource_id})"
    rescue => e
      @logger.error "[OrderValidator] 标记超匹配失败：#{e.message}"
    end
  end

  # 标记订单为过期状态
  def mark_order_expired(order)
    begin
      Orders::OrderStatusManager.new(order).set_offchain_status!(
        'expired',
        'order_expired'
      )
      @logger.debug "[OrderValidator] 订单已标记为过期：#{order.order_hash}"
    rescue => e
      @logger.error "[OrderValidator] 标记过期失败：#{e.message}"
    end
  end

  # 更新订单状态为撮合中
  def update_order_status_to_matched(order_hash)
    begin
      order = Trading::Order.find_by(order_hash: order_hash)
      return unless order
      
      # ✅ 设置为撮合中状态
      Orders::OrderStatusManager.new(order).set_offchain_status!(
        'matching',
        'order_matched_processing'
      )
      
      @logger.debug "[OrderValidator] 订单状态已更新为撮合中：#{order_hash}"
    rescue => e
      @logger.error "[OrderValidator] 更新撮合状态失败：#{e.message}"
    end
  end

  # 恢复订单状态为活跃
  def restore_order_status_to_active(order_hash)
    begin
      order = Trading::Order.find_by(order_hash: order_hash)
      return unless order
      
      Orders::OrderStatusManager.new(order).set_offchain_status!(
        'active',
        'matching_failed_restored'
      )
      @logger.debug "[OrderValidator] 订单状态已恢复为活跃：#{order_hash}"
    rescue => e
      @logger.error "[OrderValidator] 恢复订单状态失败：#{e.message}"
    end
  end

  # 检查订单是否包含原生代币（不支持 match）
  def contains_native_token?(order)
    # 使用新的数据库字段直接判断
    # ItemType::NATIVE = 0 表示原生代币（ETH/MATIC等）
    
    if order.order_direction == 'List'
      # 卖单：NFT → 代币，检查收款代币类型
      if order.consideration_item_type == 0
        @logger.debug "[OrderValidator] 卖单包含原生代币收款（consideration_item_type=0）：#{order.order_hash[0..10]}..."
        return true
      end
    elsif order.order_direction == 'Offer'
      # 买单：代币 → NFT，检查支付代币类型
      if order.offer_item_type == 0
        @logger.debug "[OrderValidator] 买单包含原生代币支付（offer_item_type=0）：#{order.order_hash[0..10]}..."
        return true
      end
    end
    
    false
  rescue => e
    @logger.error "[OrderValidator] 检查原生代币失败：#{e.message}"
    # 安全起见，出错时认为包含原生代币，不参与撮合
    true
  end

  def skip_balance_validation?
    return false unless ENV['INTEGRATION_TEST_SKIP_BALANCE_CHECK'] == 'true'

    @logger.info "[OrderValidator] ⚠️ INTEGRATION_TEST_SKIP_BALANCE_CHECK=true，降级跳过余额/授权校验"
    true
  end
end 
