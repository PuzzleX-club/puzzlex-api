namespace :event_listener do
  desc "重置事件监听器的区块高度"
  task reset_block: :environment do
    puts "🔄 重置事件监听器区块高度..."
    
    # 获取当前环境的创世区块
    genesis_block = Rails.application.config.x.blockchain.event_listener_genesis_block
    
    # 获取当前区块号
    service = Seaport::ContractService.new
    current_block = service.latest_block_number
    
    puts "📊 当前环境: #{Rails.env}"
    puts "📊 创世区块: #{genesis_block}"
    puts "📊 当前区块: #{current_block}" if current_block
    
    # 询问用户选择
    puts "\n请选择重置方式:"
    puts "1. 重置到创世区块 (#{genesis_block})"
    puts "2. 重置到当前区块 (#{current_block || '无法获取'})"
    puts "3. 重置到指定区块"
    puts "4. 取消操作"
    
    print "\n请输入选项 (1-4): "
    choice = STDIN.gets.chomp
    
    case choice
    when '1'
      reset_to_block(genesis_block)
    when '2'
      if current_block
        reset_to_block(current_block)
      else
        puts "❌ 无法获取当前区块号"
        exit 1
      end
    when '3'
      print "请输入区块号: "
      block_number = STDIN.gets.chomp.to_i
      if block_number > 0
        reset_to_block(block_number)
      else
        puts "❌ 无效的区块号"
        exit 1
      end
    when '4'
      puts "🚫 操作已取消"
      exit 0
    else
      puts "❌ 无效的选项"
      exit 1
    end
  end
  
  desc "显示事件监听器当前状态"
  task status: :environment do
    puts "\n📊 事件监听器状态:"
    puts "=" * 60
    
    # 从数据库读取状态
    status = Onchain::EventListenerStatus.first
    if status
      puts "ID: #{status.id}"
      puts "最后处理区块: #{status.last_processed_block}"
      puts "最后更新时间: #{status.last_updated_at}"
    else
      puts "⚠️  数据库中没有事件监听器状态记录"
    end
    
    # 从缓存读取状态
    cached_block = Rails.cache.read("last_processed_block")
    puts "\n缓存中的区块号: #{cached_block || '无'}"
    
    # 显示当前配置
    puts "\n当前环境配置:"
    puts "环境: #{Rails.env}"
    puts "创世区块: #{Rails.application.config.x.blockchain.event_listener_genesis_block}"
    
    # 获取当前链上区块
    service = Seaport::ContractService.new
    current_block = service.latest_block_number
    puts "链上当前区块: #{current_block || '无法获取'}"
    
    # 计算待处理的区块数
    if status && current_block
      pending_blocks = current_block - status.last_processed_block
      puts "\n待处理区块数: #{pending_blocks}"
    end
    
    puts "=" * 60
  end
  
  desc "强制重置到创世区块（无确认）"
  task force_reset_to_genesis: :environment do
    # 安全检查：只允许在测试环境执行
    unless Rails.env.test?
      puts "❌ 错误：此任务只能在测试环境中执行！"
      puts "当前环境：#{Rails.env}"
      exit 1
    end
    
    genesis_block = Rails.application.config.x.blockchain.event_listener_genesis_block
    puts "⚠️  强制重置到创世区块: #{genesis_block}"
    reset_to_block(genesis_block)
  end
  
  desc "清除所有事件监听器状态（危险操作）"
  task clear_all: :environment do
    puts "\n⚠️  警告: 这将删除所有事件监听器状态记录！"
    print "确定要继续吗？输入 'yes' 确认: "
    
    confirmation = STDIN.gets.chomp
    if confirmation.downcase == 'yes'
      # 删除数据库记录
      Onchain::EventListenerStatus.destroy_all
      
      # 清除缓存
      Rails.cache.delete("last_processed_block")
      
      puts "✅ 已清除所有事件监听器状态"
    else
      puts "🚫 操作已取消"
    end
  end
  
  private
  
  def reset_to_block(block_number)
    # 更新数据库
    status = Onchain::EventListenerStatus.find_or_initialize_by(id: 1)
    status.update!(
      last_processed_block: block_number,
      last_updated_at: Time.current
    )
    
    # 更新缓存
    Rails.cache.write("last_processed_block", block_number)
    
    puts "✅ 已重置到区块 ##{block_number}"
    puts "📊 更新时间: #{Time.current}"
    
    # 显示更新后的状态
    Rake::Task['event_listener:status'].invoke
  end
end
