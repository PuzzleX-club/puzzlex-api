# app/services/orders/event_applier.rb

module Orders::EventApplier
  def self.apply_event(event_record)
    # 如果事件已同步，则不重复处理
    return if event_record.synced

    case event_record.event_name
    when "OrderValidated"
      apply_single_order_event(event_record, set_offchain_active: true)
    when "OrderFulfilled"
      apply_single_order_event(event_record)
    when "OrderCancelled"
      apply_single_order_event(event_record)
    when "OrdersMatched"
      # 对于多订单匹配事件，从 matched_orders 中获取多个订单hash
      matched_orders = JSON.parse(event_record.matched_orders) rescue []
      if matched_orders.empty?
        Rails.logger.warn "OrdersMatched event with no matched_orders data, event_id=#{event_record.id}"
        event_record.update!(synced: true)
        return
      end

      matched_orders.each do |o_hash|
        order = Trading::Order.find_by(order_hash: o_hash)
        unless order
          record_unmatched_order_event(event_record, o_hash)
          next
        end

        # 更新链上状态
        result = Orders::OrderStatusUpdater.update_order_status(o_hash)
        if result[:error].present?
          Rails.logger.error "Failed to update order status for matched order #{o_hash}: #{result[:error]}"
        else
          Orders::OrderStatusManager.new(order).set_offchain_status!(
            'matching',
            'chain_matched',
            { event: 'OrdersMatched', transaction_hash: event_record.transaction_hash }
          )
          # 同步记录
          append_sync_record(order, event_record)
        end
      end

      # 处理完成，将事件标记为已同步
      event_record.update!(synced: true)
    else
      # 未处理的事件类型
      Rails.logger.info "Unhandled event type: #{event_record.event_name}"
      event_record.update!(synced: true)
    end
  end

  def self.apply_single_order_event(event_record, set_offchain_active: false)
    order_hash = event_record.order_hash
    unless order_hash
      Rails.logger.warn "Event #{event_record.id} of type #{event_record.event_name} has no order_hash"
      event_record.update!(synced: true)
      return
    end

    order = Trading::Order.find_by(order_hash: order_hash)
    unless order
      # 记录unmatched事件信息
      record_unmatched_order_event(event_record, order_hash)
      event_record.update!(synced: true)
      return
    end

    # 从合约获取最新状态并更新
    result = Orders::OrderStatusUpdater.update_order_status(order_hash)
    if result[:error].present?
      Rails.logger.error "Failed to update order status for order #{order_hash}: #{result[:error]}"
    else
      if set_offchain_active
        Orders::OrderStatusManager.new(order).set_offchain_status!(
          'active',
          'chain_validated',
          { event: event_record.event_name }
        )
      end
      # 将本次同步信息记录
      append_sync_record(order, event_record)
    end

    # 标记事件为已同步
    event_record.update!(synced: true)
  end

  def self.append_sync_record(order, event_record)
    synced_at_data = order.synced_at || {}
    synced_history = synced_at_data['synced_history'] || []

    sync_record = {
      "timestamp" => Time.now.utc.iso8601,
      "hash" => event_record.transaction_hash,
      "logindex" => event_record.log_index,
      "event_id" => event_record.id
    }

    synced_history << sync_record
    synced_at_data['synced_history'] = synced_history

    order.update!(synced_at: synced_at_data)
  end

  def self.record_unmatched_order_event(event_record, order_hash)
    Trading::UnmatchedOrderEvent.create!(
      order_hash: order_hash,
      event_name: event_record.event_name,
      transaction_hash: event_record.transaction_hash,
      log_index: event_record.log_index,
      block_number: event_record.block_number,
      block_timestamp: event_record.block_timestamp,
      event_data: event_record.attributes
    )
    Rails.logger.warn "No matched order found for hash #{order_hash}, recorded in unmatched_order_events"
  end

  def self.create_items_and_fills(order, items_data, fills_data)
    # 在创建 items 时，先查找已有的items记录，避免重复创建
    existing_items_map = Trading::OrderItem.where(order_id: order.id).index_by(&:token_id)
    Rails.logger.info "Existing items: #{existing_items_map.keys.join(', ')}"
    items_map = {}
    items_data.each do |item|
      Rails.logger.info "Processing item: #{item}"
      # 检查该token_id是否已存在
      if existing_items_map[item["token_id"]]
        # 已存在的item，直接复用
        oi = existing_items_map[item["token_id"]]
      else
        # 不存在则创建新记录
        Rails.logger.info "Creating new OrderItem for token_id=#{item["token_id"]}"
        oi = Trading::OrderItem.create!(
          order: order,
          role: item["role"],
          token_address: item["token_address"],
          token_id: item["token_id"],
          start_amount: item["start_amount"],
          end_amount: item["end_amount"],
          start_price_distribution: item["start_price_distribution"],
          end_price_distribution: item["end_price_distribution"]
        )
      end
      items_map[item["token_id"]] = oi
    end

    # 创建fills
    # 现在的fills_data已经是分组好的结构:
    # [
    #   {
    #     "token_address": "...",
    #     "item_type": 3,
    #     "token_id": "12345",
    #     "recipients": [
    #       { "address": "...", "amount": "..." },
    #       ...
    #     ],
    #     "transaction_hash": "...",
    #     "log_index": ...,
    #     "block_timestamp": ...
    #   },
    #   ...
    # ]
    Rails.logger.info "Fills data: #{fills_data}"
    Rails.logger.info "items_map data: #{items_map}"
    fills_data.each do |fill|
      oi = items_map[fill["token_id"]]
      next unless oi

      distribution_array = fill["distribution"]  # 该字段存的价格分布 array
      market_id_val = 0  # 默认给 0

      if distribution_array.is_a?(Array) && distribution_array.size == 1
        dist_item = distribution_array.first
        # 取出token_address
        price_address_from_dist = dist_item["token_address"]

        # 在criteria订单的情况下，token_id是criteria，无法直接用来获取item_id，将出现意外返回
        # 调整为从order中获取market_id

        # item_id = ::Blockchain::TokenIdParser.new.item_id_int(fill["token_id"]) || 0

        # 调用 MarketIdParser
        # parser = MarketData::MarketIdParser.new(
        #   item_id: item_id,
        #   price_address: price_address_from_dist
        # )
        # # parser.market_id 需在 Parser 里定义方法
        # # 例如把 @item_id+@price_token_type_key 转成 string 或 int
        # market_id_val = parser.market_id.to_i || 0
        market_id_val = order.market_id.to_i || 0
      else
        # 如果 distribution_array.size !=1，则说明是多分布(或无分布) => market_id=0
        Rails.logger.warn "Fill has distribution size != 1, default market_id=0"
      end

      # 幂等性检查：避免重复创建相同的 OrderFill 记录
      existing_fill = Trading::OrderFill.find_by(
        transaction_hash: fill["transaction_hash"],
        log_index: fill["log_index"]
      )
      if existing_fill
        Rails.logger.info "OrderFill already exists for tx_hash=#{fill["transaction_hash"]}, log_index=#{fill["log_index"]}, skipping"
        next
      end

      Trading::OrderFill.create!(
        order: order,
        order_item: oi,
        filled_amount: fill["filled_amount"],
        price_distribution: fill["distribution"],
        transaction_hash: fill["transaction_hash"],
        log_index: fill["log_index"],
        block_timestamp: fill["block_timestamp"],
        market_id: market_id_val,
        buyer_address: fill["buyer_address"],
        seller_address: fill["seller_address"],
        event_id: fill["event_id"]
      )
    end
  end


end


