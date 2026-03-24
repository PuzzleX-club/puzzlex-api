# app/services/orders/item_and_fill_extractor.rb
module Orders
  class ItemAndFillExtractor
    # 统一入口函数
    def self.extract_data(event_record, order)
      event_name = event_record.event_name
      items_data = []
      fills_data = []

      case event_name
      when "OrderValidated"
        # 提取items_data
        items_data = extract_items_data_from_event(event_record, order)
        # fills_data 为空数组
      when "OrderFulfilled"
        # 此时不提取items_data，但提取fills_data
        Rails.logger.warn "开始提取item和fills_data"
        items_data = extract_items_data_from_event(event_record, order)
        fills_data = extract_fills_data_from_event(event_record, order)
      when "OrdersMatched"
        # 对于匹配订单事件，如果 order_hash 为 nil，需要对 matched_orders 进行遍历处理
        fills_data = extract_fills_data_from_event(event_record, order)
      else
        # 对其他事件不提取任何数据
      end

      [items_data, fills_data]
    end

    # 新增方法：从OrderFulfilled事件中提取买方和卖方地址
    def self.extract_buyer_seller_addresses(event_record, order)
      return [nil, nil] unless event_record.event_name == "OrderFulfilled"

      # 从事件中获取offerer和recipient（都是一级字段）
      offerer = event_record.offerer
      recipient = event_record.recipient
      
      return [nil, nil] if offerer.blank? || recipient.blank?

      # 根据订单方向确定买方和卖方
      case order.order_direction
      when 'List'
        # List订单(卖单): offerer是卖方，recipient是买方
        buyer_address = recipient
        seller_address = offerer
      when 'Offer'  
        # Offer订单(买单): offerer是买方，recipient是卖方
        buyer_address = offerer
        seller_address = recipient
      else
        Rails.logger.warn "Unknown order_direction: #{order.order_direction} for order #{order.order_hash}"
        return [nil, nil]
      end

      [buyer_address, seller_address]
    end

    # 主方法：从event中提取items_data
    def self.extract_items_data_from_event(event_record, order)
      # 仅处理 OrderFulfilled 和 OrderValidated 事件
      return [] unless %w[OrderFulfilled OrderValidated].include?(event_record.event_name)

      offer_items = JSON.parse(event_record.offer || "[]")
      consideration_items = JSON.parse(event_record.consideration || "[]")

      # 根据 order.order_direction 决定 item_side 和 price_side
      sides = determine_sides_by_direction(order.order_direction)
      item_side = sides[:item_side]
      price_side = sides[:price_side]

      items_data = []
      # 根据 item_side 处理item
      (item_side == :offer ? offer_items : consideration_items).each do |it|
        # it 就是从event的offer或consideration中解析出来的单个物品数据
        # 这里的 it 在传给 build_item_data 方法时，对应build_item_data中的entry参数
        items_data << build_item_data(it, event_record, order,is_item: true)
      end

      # 对于价格侧不构造数据
      # (price_side == :offer ? offer_items : consideration_items).each do |pt|
      #   items_data << build_item_data(pt, event_record, is_item: false)
      # end

      items_data
    end

    # 根据order_direction确定item和price侧别
    def self.determine_sides_by_direction(order_direction)
      case order_direction
      when 'List'
        # List：卖单，offer侧是NFT（item），consideration侧是价格
        { item_side: :offer, price_side: :consideration }
      when 'Offer'
        # Offer：买单，offer侧是价格(ERC20/ETH)，consideration侧是NFT（item）
        { item_side: :consideration, price_side: :offer }
      else
        # 未知类型，默认采用List逻辑，或记录日志告警
        Rails.logger.warn "Unknown order_direction: #{order_direction}, defaulting to List logic"
        { item_side: :offer, price_side: :consideration }
      end
    end

    def self.build_item_data(entry, event_record,order, is_item:)
      token_address = "0x"+entry["token"]

      # 根据事件类型选择 identifierOrCriteria 或 identifier
      token_id = if event_record.event_name == "OrderValidated"
                   entry["identifierOrCriteria"].to_s # 使用 identifier
                 else
                   entry["identifier"].to_s # 使用 identifierOrCriteria
                 end
      # 当订单是criteria的类型时，没有startAmount和endAmount,只有amount
      start_amount = entry["startAmount"]
      end_amount = entry["endAmount"]

      if start_amount.nil? && end_amount.nil?
        start_amount = entry["amount"]
        end_amount = entry["amount"]
      end

      item_type = entry["itemType"].to_i

      role = is_item ? "item" : "price"

      if is_item
        parameters = order.parameters
        offerer = parameters["offerer"]
        offer_data = parameters["offer"] || []
        consideration_data = parameters["consideration"] || []

        sides = determine_sides_by_direction(order.order_direction)
        item_side = sides[:item_side]
        price_side = sides[:price_side]

        # 判断entry属于item_side还是price_side（以决定role）
        # is_item为true时该物品来自item_side
        # 如果 is_item = true 且 item_side = :offer，则 role='offer'
        # 如果 is_item = true 且 item_side = :consideration，则 role='consideration'

        # 如果 is_item = false 表示是价格侧的物品，目前没记录price侧
        # 希望统一用role字段来记录offer/consideration，那么对price侧也可以同理处理

        actual_role = if is_item
                        (item_side == :offer) ? 'offer' : 'consideration'
                      else
                        (price_side == :offer) ? 'offer' : 'consideration'
                      end

        price_items = (price_side == :offer) ? offer_data : consideration_data

        # 构建分布（可能包含多个token条目）
        distribution = build_recipients_distribution(price_items, offerer)

        {
          "role" => actual_role,
          "token_address" => token_address,
          "token_id" => token_id,
          "start_amount" => start_amount,
          "end_amount" => end_amount,
          "start_price_distribution" => distribution,
          "end_price_distribution" => distribution
        }
      else
        # price侧不进行任何记录
        nil
      end
    end

    def self.build_recipients_distribution(price_items, offerer)
      # 假设price_items中有多个entry，每个entry可能有startAmount/endAmount和recipient
      # 格式示例（从问题中的consideration项）：
      # [
      #   {"token": "0x0000...", "itemType":0, "startAmount":"100000000000000000", "endAmount":"100000000000000000", "recipient":"0xeb8A03C8..."},
      #   {"token": "0x0000...", "itemType":0, "startAmount":"500000000000000",    "endAmount":"500000000000000",    "recipient":"0x2d501e50..."},
      #   {"token": "0x0000...", "itemType":0, "startAmount":"100000000000000000","endAmount":"100000000000000000", "recipient":"0x83199fF5..."}
      # ]
      # 将这些金额转化为比例。例如，将所有startAmount加总，然后每个recipient的比例=自家startAmount/总和

      # 1. 按 (token, identifierOrCriteria, itemType) 分组
      grouped = price_items.group_by { |c| [c["token"].downcase, c["identifierOrCriteria"], c["itemType"].to_s] }

      distribution = []

      grouped.each do |(token_address, token_id, item_type), group_items|
        # 2. 对该分组内的recipient金额进行汇总
        # recipient_amounts = { recipient_address => total_start_amount }
        recipient_amounts = Hash.new(0)
        total_start = 0

        group_items.each do |c|
          amt = c["startAmount"].to_i
          recipient_amounts[c["recipient"]] += amt
          total_start += amt
        end

        # 如果 total_start = 0，说明此分组下没有可分配金额，使用默认
        if total_start == 0
          recipients = [{ "address" => offerer, "amount" => "1.0" }]
        else
          # 计算比例
          recipients = recipient_amounts.map do |addr, amt|
            ratio = amt.to_f / total_start.to_f
            { "address" => addr, "amount" => ratio.to_s }
          end
        end

        # 3. 为此分组生成一个distribution entry
        distribution << {
          "token_address" => "0x#{token_address.gsub(/^0x/,'')}",
          "item_type" => item_type.to_i,
          "token_id" => token_id.to_s,
          "recipients" => recipients
        }
      end

      distribution
    end

    def self.extract_fills_data_from_event(event_record, order)
      return [] unless %w[OrderFulfilled OrdersMatched].include?(event_record.event_name)

      case event_record.event_name
      when "OrderFulfilled"
        offer_items = JSON.parse(event_record.offer || "[]")
        consideration_items = JSON.parse(event_record.consideration || "[]")

        # 根据订单方向决定 item 来自 offer 还是 consideration
        sides = determine_sides_by_direction(order.order_direction)
        item_side = sides[:item_side]
        price_side = sides[:price_side]

        # 在本例中，items_data曾经是从item_side提取，这里对于fills，我们同样从item_side提取本次填充的物品信息
        # 但是根据需求，fills_data需要全面的价格分布。因此我们需要从 price_side 对应的数据中构建分布信息
        # 实际上，对fills我们同样需要从 price_side 提取价格信息以构建 recipients 分布。
        item_entries = (item_side == :offer) ? offer_items : consideration_items
        price_entries = (price_side == :offer) ? offer_items : consideration_items

        # 计算 filled_amount 为 item_entries 的 end_amount 总和
        filled_amount = item_entries.sum { |item| item["amount"].to_i }

        # 从event中提取price_distribution
        price_distribution = build_price_distribution_from_event(price_entries, event_record)

        # 提取买方和卖方地址
        buyer_address, seller_address = extract_buyer_seller_addresses(event_record, order)

        # 创建 fills_data，不匹配 itemType 和 token_id
        fills_data = item_entries.map do |item|
          # 根据事件类型选择 identifierOrCriteria 或 identifier
          token_id = if event_record.event_name == "OrderValidated"
                       item["identifierOrCriteria"].to_s # 使用 identifier
                     else
                       item["identifier"].to_s # 使用 identifierOrCriteria
                     end
          {
            "itemType" => item["itemType"].to_i,
            "token_address" => "0x" + item["token"].downcase,
            "token_id" => token_id,
            "distribution" => price_distribution, # 不进行匹配
            "filled_amount" => filled_amount,
            "transaction_hash" => event_record.transaction_hash,
            "log_index" => event_record.log_index,
            "block_timestamp" => event_record.block_timestamp,
            "buyer_address" => buyer_address,
            "seller_address" => seller_address,
            "event_id" => event_record.id
          }
        end
        Rails.logger.warn "fills_data: #{fills_data}"

        fills_data
      when "OrdersMatched"
        matched_orders = JSON.parse(event_record.matched_orders || "[]")
        fills_data = []

        matched_orders.each do |o_hash|
          matched_order = Trading::Order.find_by(order_hash: o_hash)
          next unless matched_order

          parameters = matched_order.parameters
          offer_data = parameters["offer"] || []
          consideration_data = parameters["consideration"] || []
          offerer = parameters["offerer"]
          order_direction = matched_order.order_direction

          sides = determine_sides_by_direction(order_direction)
          item_side = sides[:item_side]
          price_side = sides[:price_side]

          # 提取 item_entries
          item_entries = (item_side == :offer) ? offer_data : consideration_data

          price_entries = (price_side == :offer) ? offer_data : consideration_data

          start_time = parameters["startTime"].to_i
          end_time = parameters["endTime"].to_i
          current_block_time = event_record.block_timestamp.to_i
          time_range = end_time - start_time
          if time_range <= 0
            # 无有效时间区间，无法插值
            next
          end

          # 基于当前区块时间计算线性插值进度（时间进度）
          time_progress = (current_block_time <= start_time) ? 0.0 : ((current_block_time - start_time).to_f / time_range.to_f)
          time_progress = 1.0 if time_progress > 1.0
          time_progress = 0.0 if time_progress < 0.0

          # 计算填充比例
          total_size = matched_order.total_size.to_i
          total_filled = matched_order.total_filled.to_i

          previous_fraction = if total_size == 0
                                0.0
                              else
                                total_filled.to_f / total_size.to_f
                              end

          # TODO: For future upgrade, consider partial fill logic if Seaport evolves.
          # Currently, matchOrders implies fully filled = 1.
          new_total_filled = 1
          new_fraction = 1.0

          difference_fraction = new_fraction - previous_fraction
          if difference_fraction <= 0
            # 没有新增填充量
            next
          end

          # 计算填充数量的增量
          # 由于 total_size 是相对比例，需要计算所有 items 的绝对总和
          # todo: 这个方法不对，需要判断item_side，直接求和
          absolute_total_size = item_entries_sum(item_entries, time_progress)
          filled_amount_increment = (difference_fraction * absolute_total_size).to_i

          # 从订单中获取价格分布信息，而不是从event_record
          # 这假设订单的 price_side 包含了必要的价格信息
          price_distribution = build_price_distribution_from_order(price_entries, difference_fraction, time_progress)



          # 创建 fills_data，不匹配 itemType 和 token_id，并添加 total_amount
          item_fills_data = item_entries.map do |item|
            {
              "itemType" => item["itemType"].to_i,
              "token_address" => "0x" + item["token"].downcase,
              "token_id" => item["identifierOrCriteria"].to_s,
              "distribution" => price_distribution, # 不进行匹配
              "filled_amount" => filled_amount_increment,
              "transaction_hash" => event_record.transaction_hash,
              "log_index" => event_record.log_index,
              "block_timestamp" => event_record.block_timestamp,
            }
          end

          fills_data.concat(item_fills_data)

          # grouped = price_entries.group_by { |c| [c["token"].downcase, c["identifierOrCriteria"], c["itemType"].to_s] }
          #
          # grouped.each do |(token_address, token_id, item_type), group_items|
          #   total_start = 0
          #   total_end = 0
          #   recipient_start_amounts = Hash.new(0)
          #   recipient_end_amounts = Hash.new(0)
          #
          #   group_items.each do |c|
          #     start_amt = c["startAmount"].to_i
          #     end_amt = c["endAmount"].to_i
          #     recipient_start_amounts[c["recipient"]] += start_amt
          #     recipient_end_amounts[c["recipient"]] += end_amt
          #     total_start += start_amt
          #     total_end += end_amt
          #   end
          #
          #   # 若无可分配量，跳过
          #   if total_end == 0 && total_start == 0
          #     next
          #   end
          #
          #   # 基于当前时间对整体做线性插值
          #   # now_amount = start_amount + (end_amount - start_amount)*time_progress
          #   now_amount = (total_start + (total_end - total_start)*time_progress).to_i
          #
          #   # 使用订单差额比例对 now_amount 进行缩放
          #   difference_abs = (now_amount * difference_fraction).to_i
          #   next if difference_abs <= 0
          #
          #   # 对每个recipient基于时间插值，再乘差额比例
          #   recipients = recipient_start_amounts.map do |addr, start_amt|
          #     end_amt = recipient_end_amounts[addr]
          #     now_recipient_amount = (start_amt + (end_amt - start_amt)*time_progress).to_i
          #     recipient_increment = (now_recipient_amount * difference_fraction).to_i.to_s
          #     { "address" => addr, "amount" => recipient_increment }
          #   end
          #
          #   fills_data << {
          #     "token_address" => "0x#{token_address.gsub(/^0x/,'')}",
          #     "item_type" => item_type.to_i,
          #     "token_id" => token_id.to_s,
          #     "recipients" => recipients,
          #     "transaction_hash" => event_record.transaction_hash,
          #     "log_index" => event_record.log_index,
          #     "block_timestamp" => event_record.block_timestamp
          #   }
          # end
        end


        fills_data
      end
    end

    def self.build_price_distribution_from_event(price_items, event_record)
      # 按 (token, identifier, itemType) 分组 ，注意fulfill的返回数据中，没有identifierOrCriteria字段，只有identifier字段
      grouped = price_items.group_by { |c| [c["token"].downcase, c["identifier"], c["itemType"].to_s] }

      fills_data = []
      grouped.each do |(token_address, token_id, item_type), group_items|
        # 汇总每个recipient的startAmount和endAmount（这里选择使用startAmount为原始数据）
        # 如果您想同时考虑endAmount，也可类似汇总并存储
        recipient_amounts = Hash.new(0)
        total_start = 0
        group_items.each do |c|
          amt = c["amount"].to_i
          recipient_amounts[c["recipient"]] += amt
          total_start += amt
        end

        # 不进行比例转换，直接记录原始startAmount为amount
        recipients = recipient_amounts.map do |addr, amt|
          { "address" => addr, "amount" => amt.to_s }
        end

        # 计算 total_amount
        total_amount = recipients.sum { |r| r["amount"].to_i }

        # 暂不在价格分布中添加区块信息
        # "transaction_hash" => event_record.transaction_hash,
        # "log_index" => event_record.log_index,
        # "block_timestamp" => event_record.block_timestamp
        fills_data << {
          "token_address" => "0x#{token_address.gsub(/^0x/,'')}",
          "item_type" => item_type.to_i,
          "token_id" => token_id.to_s,
          "recipients" => recipients,
          "total_amount" => total_amount.to_s, # 添加 total_amount
        }
      end

      fills_data
    end

    # 从订单中构建 price_distribution
    def self.build_price_distribution_from_order(price_entries, difference_fraction, time_progress)
      # 按 (token, identifierOrCriteria, itemType) 分组
      grouped = price_entries.group_by { |c| [c["token"].downcase, c["identifierOrCriteria"], c["itemType"].to_s] }

      price_distribution = []

      grouped.each do |(token_address, token_id, item_type), group_items|
        total_start = 0
        total_end = 0
        recipient_start_amounts = Hash.new(0)
        recipient_end_amounts = Hash.new(0)

        group_items.each do |c|
          # match订单的时候，不会存在criteria类型的订单，所以这里不需要判断
          start_amt = c["startAmount"].to_i
          end_amt = c["endAmount"].to_i
          recipient_start_amounts[c["recipient"]] += start_amt
          recipient_end_amounts[c["recipient"]] += end_amt
          total_start += start_amt
          total_end += end_amt
        end

        # 若无可分配量，跳过
        if total_end == 0 && total_start == 0
          next
        end

        # 基于时间进度计算当前的金额
        # now_amount = start_amount + (end_amount - start_amount)*time_progress
        now_amount = (total_start + (total_end - total_start) * time_progress).to_i

        # 使用订单差额比例对 now_amount 进行缩放
        difference_abs = (now_amount * difference_fraction).to_i
        next if difference_abs <= 0

        # 对每个recipient基于时间插值，再乘差额比例
        recipients = recipient_start_amounts.map do |addr, start_amt|
          end_amt = recipient_end_amounts[addr]
          now_recipient_amount = (start_amt + (end_amt - start_amt) * time_progress).to_i
          recipient_increment = (now_recipient_amount * difference_fraction).to_i.to_s
          { "address" => addr, "amount" => recipient_increment }
        end

        # 计算总金额
        total_amount = recipients.sum { |r| r["amount"].to_i }

        price_distribution << {
          "token_address" => "0x#{token_address.gsub(/^0x/,'')}",
          "item_type" => item_type.to_i,
          "token_id" => token_id.to_s,
          "recipients" => recipients,
          "total_amount" => total_amount.to_s # 添加 total_amount 字段
        }
      end

      price_distribution
    end

    # 新增方法：计算订单的总绝对大小
    def self.item_entries_sum(item_entries, time_progress)
      if item_entries.length > 1
        Rails.logger.warn "Expected only one item_entry, but got #{item_entries.length}. Computing now_amount for each and summing."
      end
      # 计算now_amount for each item and sum them
      item_entries.sum do |item|
        (item["startAmount"].to_i + (item["endAmount"].to_i - item["startAmount"].to_i) * time_progress).to_i
      end
    end


  end
end