namespace :events do
  desc "重新处理缺失的OrderFulfilled事件"
  task :reprocess_missing => :environment do
    target_tx_hash = ENV['TX_HASH'] || '0xf3655d6414a56a0e8a5afd430503b5e523d69873a13d696aedc75bd8337bfeef'
    
    puts "=== 重新处理缺失的OrderFulfilled事件 ==="
    puts "目标交易: #{target_tx_hash}"
    
    # 1. 检查当前数据库中的事件记录
    existing_events = Trading::OrderEvent.where(
      transaction_hash: target_tx_hash, 
      event_name: 'OrderFulfilled'
    )
    
    puts "\n当前数据库中的事件记录："
    existing_events.each do |event|
      puts "  - ID: #{event.id}, Order Hash: #{event.order_hash}, Log Index: #{event.log_index}"
    end
    puts "  总计: #{existing_events.count} 个事件"
    
    # 2. 获取区块号（从现有事件中获取，或者手动指定）
    if existing_events.any?
      block_number = existing_events.first.block_number
      puts "\n从现有事件获取区块号: #{block_number}"
    else
      puts "\n❌ 没有找到现有事件记录，需要手动指定区块号"
      puts "使用方法: rake events:reprocess_missing TX_HASH=0x... BLOCK_NUMBER=123456"
      exit 1
    end
    
    # 3. 直接从区块链获取该交易的所有OrderFulfilled事件
    puts "\n=== 从区块链重新获取事件 ==="
    
    service = Seaport::ContractService.new
    
    # 获取该特定区块的所有OrderFulfilled事件
    events_from_chain = service.get_event_logs(
      event_name: "OrderFulfilled",
      from_block: block_number,
      to_block: block_number
    )
    
    puts "从区块 #{block_number} 获取到 #{events_from_chain&.length || 0} 个OrderFulfilled事件"
    
    # 4. 筛选出目标交易的事件
    target_events = events_from_chain&.select { |event| 
      event[:transaction_hash] == target_tx_hash 
    } || []
    
    puts "目标交易 #{target_tx_hash} 的事件数量: #{target_events.length}"
    
    if target_events.empty?
      puts "❌ 没有找到目标交易的OrderFulfilled事件"
      exit 1
    end
    
    # 5. 显示所有找到的事件
    puts "\n从区块链获取到的事件："
    target_events.each_with_index do |event, index|
      puts "  事件 #{index + 1}:"
      puts "    - Order Hash: #{event[:orderHash]}"
      puts "    - Log Index: #{event[:log_index]}"
      puts "    - Offerer: #{event[:offerer]}"
      puts "    - Recipient: #{event[:recipient]}"
      puts "    - 是否已在数据库: #{existing_events.any? { |e| e.log_index == event[:log_index] }}"
    end
    
    # 6. 找出缺失的事件
    missing_events = target_events.reject { |chain_event|
      existing_events.any? { |db_event| 
        db_event.log_index == chain_event[:log_index] 
      }
    }
    
    puts "\n缺失的事件数量: #{missing_events.length}"
    
    if missing_events.empty?
      puts "✅ 所有事件都已存在于数据库中"
      exit 0
    end
    
    # 7. 处理缺失的事件
    puts "\n=== 处理缺失的事件 ==="
    
    missing_events.each_with_index do |event, index|
      puts "\n处理缺失事件 #{index + 1}:"
      puts "  - Order Hash: #{event[:orderHash]}"
      puts "  - Log Index: #{event[:log_index]}"
      
      begin
        # 为缺失的事件添加必要的元数据
        event[:model] = Trading::OrderEvent
        event[:event_name] = "OrderFulfilled"
        event[:block_number] = block_number
        event[:block_timestamp] = existing_events.first.block_timestamp
        
        # 手动调用事件处理逻辑
        Orders::EventListener.process_event(event)
        
        puts "  ✅ 事件处理成功"
        
      rescue => e
        puts "  ❌ 事件处理失败: #{e.message}"
        puts "     #{e.backtrace.first}"
      end
    end
    
    # 8. 验证结果
    puts "\n=== 验证结果 ==="
    final_events = Trading::OrderEvent.where(
      transaction_hash: target_tx_hash, 
      event_name: 'OrderFulfilled'
    )
    
    puts "最终数据库中的事件数量: #{final_events.count}"
    final_events.each do |event|
      puts "  - ID: #{event.id}, Order Hash: #{event.order_hash}, Log Index: #{event.log_index}"
    end
    
    if final_events.count == target_events.length
      puts "\n✅ 所有事件都已正确记录到数据库"
    else
      puts "\n❌ 仍有事件缺失，需要进一步调查"
    end
  end
  
  desc "强制重新处理指定交易的所有事件"
  task :force_reprocess => :environment do
    target_tx_hash = ENV['TX_HASH']
    block_number = ENV['BLOCK_NUMBER']&.to_i
    
    unless target_tx_hash && block_number
      puts "使用方法: rake events:force_reprocess TX_HASH=0x... BLOCK_NUMBER=123456"
      exit 1
    end
    
    puts "=== 强制重新处理事件 ==="
    puts "交易: #{target_tx_hash}"
    puts "区块: #{block_number}"
    
    # 1. 删除现有的事件记录
    existing_events = Trading::OrderEvent.where(transaction_hash: target_tx_hash)
    puts "删除现有的 #{existing_events.count} 个事件记录"
    existing_events.destroy_all
    
    # 2. 重新获取和处理事件
    service = Seaport::ContractService.new
    
    ["OrderFulfilled", "OrderValidated", "OrderCancelled", "OrdersMatched"].each do |event_name|
      puts "\n处理 #{event_name} 事件..."
      
      events = service.get_event_logs(
        event_name: event_name,
        from_block: block_number,
        to_block: block_number
      )
      
      target_events = events&.select { |event| event[:transaction_hash] == target_tx_hash } || []
      
      puts "找到 #{target_events.length} 个 #{event_name} 事件"
      
      target_events.each do |event|
        event[:model] = Trading::OrderEvent
        event[:event_name] = event_name
        event[:block_number] = block_number
        
        begin
          Orders::EventListener.process_event(event)
          puts "  ✅ 处理 #{event_name} 事件成功"
        rescue => e
          puts "  ❌ 处理 #{event_name} 事件失败: #{e.message}"
        end
      end
    end
    
    # 3. 验证结果
    final_events = Trading::OrderEvent.where(transaction_hash: target_tx_hash)
    puts "\n最终记录的事件数量: #{final_events.count}"
    final_events.group_by(&:event_name).each do |event_name, events|
      puts "  #{event_name}: #{events.length} 个"
    end
  end
end
