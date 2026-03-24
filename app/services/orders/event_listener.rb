class Orders::EventListener
  BLOCK_BATCH_SIZE = 90
  EVENTS_TO_WATCH = [
    { name: "CounterIncremented", model: Trading::CounterEvent },
    { name: "OrderValidated", model: Trading::OrderEvent },
    { name: "OrderFulfilled", model: Trading::OrderEvent },
    { name: "OrderCancelled", model: Trading::OrderEvent },
    { name: "OrdersMatched", model: Trading::OrderEvent }
  ].freeze

  GENESIS_BLOCK = Rails.application.config.x.blockchain.event_listener_genesis_block

  # 定义事件监听主逻辑
  def self.listen_to_events
    latest_block = latest_block_number
    if latest_block.nil?
      Rails.logger.error "[EventListener] 无法获取最新区块号，跳过本次执行"
      return
    end

    Rails.logger.info "EventListener: 最新区块 #{latest_block}"

    successful_events = []
    total_events_processed = 0

    events_to_watch.each do |event|
      event_name = event[:name]
      from_block = resolve_from_block(event_name)

      if from_block > latest_block
        Rails.logger.warn "[EventListener] #{event_name} 起始区块 #{from_block} 高于最新区块 #{latest_block}，跳过"
        next
      end

      begin
        processed_count = process_event_type(event, from_block: from_block, to_block: latest_block)
        total_events_processed += processed_count
        successful_events << event_name
        update_checkpoint(event_name, latest_block)
      rescue => e
        Rails.logger.error "❌ [EventListener] 处理 #{event_name} 失败: #{e.class} - #{e.message}"
        record_retry_range(event_name, from_block, latest_block, e)
      end
    end

    if successful_events.size == events_to_watch.size
      update_checkpoint('global', latest_block)
    end

    if total_events_processed.zero?
      Rails.logger.debug "✅ [EventListener] 本轮扫描完成：无新事件"
    else
      Rails.logger.info "✅ [EventListener] 本轮处理完成：共 #{total_events_processed} 个事件"
    end
  rescue => e
    Rails.logger.error "Error in EventListener: #{e.message}, backtrace: #{e.backtrace.join("\n")}"
  end

  private

  def self.events_to_watch
    EVENTS_TO_WATCH
  end

  def self.process_event_type(event, from_block:, to_block:)
    Rails.logger.debug "处理事件类型: #{event[:name]}, 区块范围: #{from_block}-#{to_block}"

    logs = Array(fetch_events(event_name: event[:name], from_block: from_block, to_block: to_block))
    return 0 if logs.empty?

    Rails.logger.info "📋 [EventListener] 发现 #{logs.size} 个 #{event[:name]} 事件"

    logs.each_with_index do |log, index|
      event_with_metadata = log.merge(event_name: event[:name], model: event[:model])
      process_event(event_with_metadata)

      if (index + 1) % 5 == 0
        ActiveRecord::Base.connection_pool.release_connection
      end
    end

    logs.size
  ensure
    ActiveRecord::Base.connection_pool.release_connection
  end

  # 同步处理事件：立即创建Fill和更新订单状态
  # 这确保了即使异步Job失败，关键数据也已经写入
  def self.process_event_synchronously(event_record)
    order_hash = event_record.order_hash
    return unless order_hash.present?

    order = Trading::Order.find_by(order_hash: order_hash)
    unless order
      Rails.logger.warn "⚠️ [EventListener] 未找到订单: #{order_hash}"
      return
    end

    Rails.logger.info "🔄 [EventListener] 同步处理事件 #{event_record.event_name} for order #{order_hash[0..15]}..."

    begin
      items_data, fills_data = Orders::ItemAndFillExtractor.extract_data(event_record, order)
      Orders::EventApplier.create_items_and_fills(order, items_data, fills_data)
      Orders::EventApplier.apply_event(event_record)
      Rails.logger.info "✅ [EventListener] 同步处理完成: 创建了 #{items_data.size} 个items, #{fills_data.size} 个fills"
    rescue => e
      Rails.logger.error "❌ [EventListener] 同步处理失败: #{e.message}"
      Rails.logger.error "  事件: #{event_record.id}, 订单: #{order_hash}"
      Rails.logger.error "  #{e.backtrace.first(3).join("\n  ")}"
      # 失败不阻塞，异步Job会重试
    end
  end

  def self.latest_block_number
    service = Seaport::ContractService.new
    service.latest_block_number
  end

  def self.resolve_from_block(event_type)
    baseline = GENESIS_BLOCK.to_i
    value = Onchain::EventListenerStatus.last_block(event_type: event_type)

    if value.nil? || value == 'earliest'
      update_checkpoint(event_type, baseline)
      return baseline
    end

    numeric_value = value.to_i
    if numeric_value < baseline
      # 旧的 checkpoint 落后于新的创世区块，直接抬升到最新起点
      update_checkpoint(event_type, baseline)
      baseline
    else
      numeric_value
    end
  end

  def self.update_checkpoint(event_type, block_number)
    Onchain::EventListenerStatus.update_status(event_type, block_number, event_type: event_type)
  end

  def self.record_retry_range(event_type, from_block, to_block, error)
    range = Onchain::EventRetryRange.find_or_initialize_by(
      event_type: event_type,
      from_block: from_block,
      to_block: to_block
    )

    range.attempts = range.attempts.to_i + 1
    range.last_error = "#{error.class}: #{error.message}"
    range.next_retry_at = [range.next_retry_at, Time.current + 5.minutes].compact.max
    range.save!
  rescue => e
    Rails.logger.error "❌ [EventListener] 写入重试区间失败: #{e.class} - #{e.message}"
  end

  # 轮询事件
  def self.fetch_events(event_name:, from_block:, to_block:)
    service = Seaport::ContractService.new

    if from_block.is_a?(Integer) && to_block.is_a?(Integer)
      total_blocks = to_block - from_block

      if total_blocks <= BLOCK_BATCH_SIZE
        logs = service.get_event_logs(event_name: event_name, from_block: from_block, to_block: to_block)
        return assert_log_array!(logs, event_name)
      end

      all_logs = []
      current_from = from_block

      while current_from <= to_block
        current_to = [current_from + BLOCK_BATCH_SIZE - 1, to_block].min
        Rails.logger.info "Fetching #{event_name} events from block #{current_from} to #{current_to}"
        batch_logs = service.get_event_logs(event_name: event_name, from_block: current_from, to_block: current_to)
        all_logs.concat(assert_log_array!(batch_logs, event_name))
        current_from = current_to + 1
      end

      return all_logs
    end

    logs = service.get_event_logs(event_name: event_name, from_block: from_block, to_block: to_block)
    assert_log_array!(logs, event_name)
  end

  def self.assert_log_array!(logs, event_name)
    return logs if logs.is_a?(Array)

    raise RuntimeError, "Unexpected #{event_name} log payload: #{logs.inspect}"
  end

  # 处理单个事件（原实现保留）
  def self.process_event(event)
    model = event[:model]

    Rails.logger.info "Processing event #{event[:event_name]} with hash: #{event[:transaction_hash]}"
    Rails.logger.debug "Event data: #{event.inspect}"

    if event.key?(:decode_failed) && event[:decode_failed]
      Rails.logger.error "❌ 收到解析失败的事件: #{event[:event_name]}, 交易哈希: #{event[:transaction_hash]}"
      Rails.logger.error "❌ 解析错误: #{event[:decode_error]}"
      Rails.logger.error "❌ 跳过处理此事件"
      return
    end

    has_parsed_fields = case event[:event_name]
    when "OrderValidated"
      event.key?(:orderHash) && event.key?(:orderParameters)
    when "OrderFulfilled", "OrderCancelled"
      event.key?(:orderHash) && event.key?(:offerer)
    when "OrdersMatched"
      event.key?(:orderHashes)
    else
      false
    end

    if !has_parsed_fields && event.key?("topics") && event.key?("data")
      Rails.logger.error "❌ 收到未解析的原始事件数据: #{event[:transaction_hash]}"

      if event[:event_name] == "OrderFulfilled"
        Rails.logger.info "🔧 尝试手动解析 OrderFulfilled 事件"

        topics = event["topics"] || []
        offerer = topics[1] ? "0x#{topics[1][26..]}" : nil
        zone = topics[2] ? "0x#{topics[2][26..]}" : nil

        data = event["data"]
        if data && data.length > 2
          hex_data = data[2..]
          chunks = []
          (0...hex_data.length).step(64) { |i| chunks << hex_data[i, 64] }

          order_hash = chunks[0] ? "0x#{chunks[0]}" : nil
          recipient = chunks[1] ? "0x#{chunks[1][24..]}" : nil

          event[:orderHash] = order_hash
          event[:offerer] = offerer
          event[:zone] = zone
          event[:recipient] = recipient
          event[:offer] = []
          event[:consideration] = []

          Rails.logger.info "✅ 手动解析 OrderFulfilled 成功: #{order_hash}"
        else
          Rails.logger.error "❌ OrderFulfilled 手动解析失败，跳过处理"
          return
        end
      else
        Rails.logger.error "❌ 非 OrderFulfilled 事件的原始数据，跳过处理"
        return
      end
    end

    log_index_for_check = event[:log_index].is_a?(String) ? event[:log_index].to_i(16) : event[:log_index]
    return if model.exists?(transaction_hash: event[:transaction_hash], log_index: log_index_for_check)

    case event[:event_name]
    when "OrdersMatched"
      record = model.create!(
        event_name: event[:event_name],
        order_hash: nil,
        offerer: nil,
        zone: nil,
        recipient: nil,
        offer: nil,
        consideration: nil,
        transaction_hash: event[:transaction_hash],
        log_index: event[:log_index].is_a?(String) ? event[:log_index].to_i(16) : event[:log_index],
        matched_orders: event[:orderHashes].to_json,
        block_number: event[:block_number],
        block_timestamp: event[:block_timestamp]
      )
    when "OrderValidated"
      parameters = event[:orderParameters] || {}
      record = model.create!(
        event_name: event[:event_name],
        order_hash: event[:orderHash],
        offerer: parameters[:offerer],
        zone: parameters[:zone],
        recipient: nil,
        offer: parameters[:offer] ? parameters[:offer].to_json : nil,
        consideration: parameters[:consideration] ? parameters[:consideration].to_json : nil,
        transaction_hash: event[:transaction_hash],
        log_index: event[:log_index].is_a?(String) ? event[:log_index].to_i(16) : event[:log_index],
        block_number: event[:block_number],
        block_timestamp: event[:block_timestamp]
      )
    else
      record = model.create!(
        event_name: event[:event_name],
        order_hash: event[:orderHash],
        offerer: event[:offerer],
        zone: event[:zone],
        recipient: event[:recipient],
        offer: event[:offer] ? event[:offer].to_json : nil,
        consideration: event[:consideration] ? event[:consideration].to_json : nil,
        transaction_hash: event[:transaction_hash],
        log_index: event[:log_index].is_a?(String) ? event[:log_index].to_i(16) : event[:log_index],
        block_number: event[:block_number],
        block_timestamp: event[:block_timestamp]
      )
    end

    case event[:event_name]
    when "OrderFulfilled", "OrderValidated"
      process_event_synchronously(record)
      Jobs::Orders::OrderEventHandlerJob.perform_async(record.id)
    else
      Jobs::Orders::OrderEventHandlerJob.perform_async(record.id)
    end
  rescue ActiveRecord::RecordNotUnique
    Rails.logger.debug "[EventListener] 跳过重复事件: tx=#{event[:transaction_hash]}, log_index=#{event[:log_index]}"
  rescue ActiveRecord::RecordInvalid => e
    Rails.logger.error "❌ [EventListener] 事件数据验证失败"
    Rails.logger.error "  事件: #{event[:event_name]}, tx: #{event[:transaction_hash]}"
    Rails.logger.error "  错误: #{e.message}"

    record = e.record
    if record
      Rails.logger.error "❌ 验证失败详情:"
      record.errors.full_messages.each do |message|
        Rails.logger.error "  - #{message}"
      end
      Rails.logger.error "❌ 失败的字段和值:"
      record.errors.each do |error|
        field_value = record.send(error.attribute) rescue nil
        Rails.logger.error "  - #{error.attribute}: '#{field_value}' (#{error.message})"
      end
    end
  rescue => e
    Rails.logger.error "❌ [EventListener] 事件处理失败"
    Rails.logger.error "  事件: #{event[:event_name]}, tx: #{event[:transaction_hash]}"
    Rails.logger.error "  错误: #{e.class} - #{e.message}"

    if Rails.env.development?
      Rails.logger.error "  事件数据: #{event.inspect}"
      Rails.logger.error "  调用栈: #{e.backtrace.first(5).join("\n  ")}"
    end
  end
end
