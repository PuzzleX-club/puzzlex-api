
module Jobs::Orders
  class OrderEventHandlerJob
    include Sidekiq::Job
    sidekiq_options queue: :events, retry: 3

    def perform(event_id)
      event_record = Trading::OrderEvent.find(event_id)
      order_hash = event_record.order_hash
      order = Trading::Order.find_by(order_hash: order_hash) if order_hash

      Rails.logger.info "[OrderEventHandler] Processing event #{event_record.event_name} for order #{order_hash}"

      # 1. 处理不同类型的事件
      case event_record.event_name
      when "OrdersMatched"
        # OrdersMatched事件：不创建新的fill记录，而是更新现有fill记录建立买卖关系
        process_matched_event(event_record)
      
        # 发布订单匹配事件
        publish_orders_matched_event(event_record)
      else
        # 其他事件（OrderFulfilled、OrderValidated等）：提取数据并创建records
        if order
          items_data, fills_data = Orders::ItemAndFillExtractor.extract_data(event_record, order)
          Rails.logger.info "items_data: #{items_data}, fills_data: #{fills_data}"
          Orders::EventApplier.create_items_and_fills(order, items_data, fills_data)
        
          # 发布订单履行事件
          publish_order_fulfilled_event(event_record, order, items_data, fills_data)
        else
          Rails.logger.warn "No order found for event #{event_record.id} with order_hash #{order_hash}"
        end
      end

      # 2. 再更新订单状态
      #    此时 create_items_and_fills 已经将 items 与 fills 数据写入数据库，
      #    order状态更新可利用最新的填充数据进行计算
      Orders::EventApplier.apply_event(event_record)
    
      # 发布订单状态更新事件
      publish_order_status_updated_event(event_record, order) if order
    end

    private

    # 处理OrdersMatched事件：更新现有fill记录以建立买卖关系
    def process_matched_event(event_record)
      matched_orders = extract_matched_orders(event_record.matched_orders)

      if matched_orders.size < 2
        Rails.logger.warn "OrdersMatched event expected at least 2 orders, got #{matched_orders.size}: #{matched_orders}"
        return
      end

      order_hashes = matched_orders.map { |hash| normalize_order_hash(hash) }.compact.uniq
      orders = Trading::Order.where(order_hash: order_hashes).to_a
      orders_by_hash = orders.index_by { |order| order.order_hash.downcase }
      missing_hashes = order_hashes.reject { |hash| orders_by_hash.key?(hash.downcase) }
      if missing_hashes.any?
        Rails.logger.error "Cannot find some orders for OrdersMatched event #{event_record.id}: missing=#{missing_hashes}"
      end

      sell_orders = orders.select { |order| order.order_direction == "List" }
      buy_orders = orders.select { |order| order.order_direction == "Offer" }

      if sell_orders.empty? || buy_orders.empty?
        Rails.logger.error(
          "Invalid order directions for OrdersMatched event #{event_record.id}: " \
          "sell_count=#{sell_orders.size}, buy_count=#{buy_orders.size}, order_hashes=#{order_hashes}"
        )
        return
      end

      transaction_hash = event_record.transaction_hash
      sell_fills = Trading::OrderFill.where(order: sell_orders, transaction_hash: transaction_hash, matched_event_id: nil)
      buy_fills = Trading::OrderFill.where(order: buy_orders, transaction_hash: transaction_hash, matched_event_id: nil)
      sell_fill_ids = sell_fills.pluck(:id)
      buy_fill_ids = buy_fills.pluck(:id)

      shared_update_payload = { matched_event_id: event_record.id }
      if buy_orders.size == 1
        buyer_address = buy_orders.first.offerer || buy_orders.first.parameters&.dig("offerer")
        shared_update_payload[:buyer_address] = buyer_address if buyer_address.present?
      end
      sell_fills.update_all(shared_update_payload) if sell_fill_ids.any?

      buy_update_payload = { matched_event_id: event_record.id }
      if sell_orders.size == 1
        seller_address = sell_orders.first.offerer || sell_orders.first.parameters&.dig("offerer")
        buy_update_payload[:seller_address] = seller_address if seller_address.present?
      end
      buy_fills.update_all(buy_update_payload) if buy_fill_ids.any?

      if sell_orders.size == 1 && buy_orders.size == 1
        Orders::SpreadAllocationRecorder.record_for_match_event!(
          matched_event: event_record,
          buy_order: buy_orders.first,
          sell_order: sell_orders.first,
          buy_fills: Trading::OrderFill.where(id: buy_fill_ids).to_a,
          sell_fills: Trading::OrderFill.where(id: sell_fill_ids).to_a
        )
      else
        Rails.logger.info(
          "Skip spread allocation for multi-order OrdersMatched event #{event_record.id}: " \
          "sell_count=#{sell_orders.size}, buy_count=#{buy_orders.size}"
        )
      end

      Rails.logger.info(
        "Updated #{sell_fill_ids.size} sell fills and #{buy_fill_ids.size} buy fills " \
        "for OrdersMatched event #{event_record.id} (sell_orders=#{sell_orders.size}, buy_orders=#{buy_orders.size})"
      )
    end
  
    # 发布订单匹配事件
    def publish_orders_matched_event(event_record)
      matched_orders = extract_matched_orders(event_record.matched_orders)
    
      Infrastructure::EventBus.publish('order.matched', {
        event_id: event_record.id,
        transaction_hash: event_record.transaction_hash,
        matched_orders: matched_orders,
        block_number: event_record.block_number,
        timestamp: event_record.block_timestamp
      })
    end

    def extract_matched_orders(raw_matched_orders)
      parsed = case raw_matched_orders
               when Array
                 raw_matched_orders
               when String
                 JSON.parse(raw_matched_orders.presence || "[]")
               when NilClass
                 []
               else
                 []
               end

      parsed.is_a?(Array) ? parsed : []
    rescue JSON::ParserError
      []
    end

    def normalize_order_hash(hash)
      value = hash.to_s.strip
      return nil if value.blank?

      value = "0x#{value}" unless value.start_with?("0x")
      value.downcase
    end
  
    # 发布订单履行事件
    def publish_order_fulfilled_event(event_record, order, items_data, fills_data)
      Infrastructure::EventBus.publish('order.fulfilled', {
        event_id: event_record.id,
        order_id: order.id,
        order_hash: order.order_hash,
        market_id: order.market_id,
        transaction_hash: event_record.transaction_hash,
        items_count: items_data.size,
        fills_count: fills_data.size,
        block_number: event_record.block_number,
        timestamp: event_record.block_timestamp
      })
    end
  
    # 发布订单状态更新事件
    def publish_order_status_updated_event(event_record, order)
      Infrastructure::EventBus.publish('order.status_updated', {
        event_id: event_record.id,
        order_id: order.id,
        order_hash: order.order_hash,
        market_id: order.market_id,
        old_status: order.onchain_status_was,
        new_status: order.onchain_status,
        transaction_hash: event_record.transaction_hash,
        block_number: event_record.block_number,
        timestamp: event_record.block_timestamp
      })
    end
  end
end
