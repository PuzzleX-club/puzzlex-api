namespace :logs do
  desc "根据trace_id查询完整的处理流程"
  task :trace, [:trace_id] => :environment do |t, args|
    trace_id = args[:trace_id]
    
    unless trace_id
      puts "用法: rails logs:trace[trace_id]"
      puts "示例: rails logs:trace[abc-123-def-456]"
      exit 1
    end
    
    puts "\n" + "="*60
    puts "查询 trace_id: #{trace_id}"
    puts "="*60
    
    # 1. 查询数据库中的撮合日志
    matching_log = Trading::OrderMatchingLog
      .where("redis_data_stored LIKE ?", "%#{trace_id}%")
      .first
      
    if matching_log
      puts "\n📊 撮合日志 (数据库):"
      puts "  ID: #{matching_log.id}"
      puts "  Market ID: #{matching_log.market_id}"
      puts "  状态: #{matching_log.status}"
      puts "  耗时: #{matching_log.total_duration_ms}ms"
      puts "  输入订单: 买单#{matching_log.input_bids_count}, 卖单#{matching_log.input_asks_count}"
      puts "  验证后: 买单#{matching_log.validated_bids_count}, 卖单#{matching_log.validated_asks_count}"
      puts "  撮合数: #{matching_log.matched_orders_count}"
      puts "  创建时间: #{matching_log.created_at.strftime('%Y-%m-%d %H:%M:%S')}"
      
      if matching_log.error_message.present?
        puts "  ❌ 错误: #{matching_log.error_message}"
        
        # 提供错误建议
        if matching_log.error_message.include?("String can't be coerced")
          puts "  💡 建议: 这是类型转换错误，订单数据中的数量字段应该是数值类型"
        elsif matching_log.error_message.include?("timeout")
          puts "  💡 建议: 撮合超时，可能需要优化算法或减少订单数量"
        end
      end
    else
      puts "\n❌ 未找到该trace_id的撮合日志"
    end
    
    # 2. 查询Rails日志
    puts "\n📝 Rails日志:"
    test_log_file = Rails.root.join("log", "test.log")
    if File.exist?(test_log_file)
      rails_logs = `grep "#{trace_id}" #{test_log_file} | tail -20`
      if rails_logs.empty?
        puts "  (无相关日志)"
      else
        puts rails_logs
      end
    else
      puts "  (日志文件不存在)"
    end
    
    # 3. 查询Sidekiq日志
    puts "\n⚡ Sidekiq日志:"
    sidekiq_log_file = Rails.root.join("log", "sidekiq_test.log")
    if File.exist?(sidekiq_log_file)
      sidekiq_logs = `grep "#{trace_id}" #{sidekiq_log_file} | tail -20`
      if sidekiq_logs.empty?
        puts "  (无相关日志)"
      else
        puts sidekiq_logs
      end
    else
      puts "  (日志文件不存在)"
    end
    
    puts "\n" + "="*60
  end
  
  desc "查看最近的撮合错误"
  task :errors, [:limit] => :environment do |t, args|
    limit = (args[:limit] || 10).to_i
    
    errors = Trading::OrderMatchingLog
      .where(status: 'failed')
      .or(Trading::OrderMatchingLog.where.not(error_message: nil))
      .order(created_at: :desc)
      .limit(limit)
    
    puts "\n" + "="*60
    puts "最近 #{limit} 条撮合错误"
    puts "="*60
    
    if errors.any?
      errors.each_with_index do |log, i|
        puts "\n#{i+1}. [#{log.created_at.strftime('%Y-%m-%d %H:%M:%S')}]"
        puts "   Market ID: #{log.market_id}"
        puts "   状态: #{log.status}"
        puts "   错误: #{log.error_message}"
        
        # 获取trace_id
        if log.redis_data_stored.present?
          begin
            data = JSON.parse(log.redis_data_stored) rescue log.redis_data_stored
            if data.is_a?(Hash) && data['trace_id']
              puts "   Trace ID: #{data['trace_id']}"
              puts "   (使用 'rails logs:trace[#{data['trace_id']}]' 查看详情)"
            end
          rescue
            # 忽略解析错误
          end
        end
        
        # 提供错误建议
        if log.error_message&.include?("String can't be coerced")
          puts "   💡 类型错误: 订单数量应该是数值，而不是字符串"
          puts "      建议修复: 检查API返回的数据格式"
        elsif log.error_message&.include?("timeout")
          puts "   💡 超时错误: 撮合时间超过30秒限制"
          puts "      建议修复: 优化撮合算法或减少单次撮合的订单数"
        elsif log.error_message&.include?("validation")
          puts "   💡 验证错误: 订单状态不满足撮合条件"
          puts "      建议修复: 确认订单已验证且未取消"
        end
      end
    else
      puts "\n✅ 没有找到撮合错误记录"
    end
    
    # 统计错误类型
    puts "\n📊 错误类型统计:"
    error_types = {}
    errors.each do |log|
      if log.error_message.present?
        key = case log.error_message
              when /String can't be coerced/
                "类型转换错误"
              when /timeout/i
                "超时错误"
              when /validation/i
                "验证错误"
              when /Redis/i
                "Redis错误"
              else
                "其他错误"
              end
        error_types[key] ||= 0
        error_types[key] += 1
      end
    end
    
    error_types.each do |type, count|
      puts "  #{type}: #{count} 次"
    end
    
    puts "\n" + "="*60
  end
  
  desc "查看撮合性能统计"
  task :performance, [:market_id] => :environment do |t, args|
    conditions = {}
    conditions[:market_id] = args[:market_id] if args[:market_id]
    
    logs = Trading::OrderMatchingLog
      .where(conditions)
      .where.not(total_duration_ms: nil)
      .order(created_at: :desc)
      .limit(100)
    
    if logs.any?
      puts "\n" + "="*60
      puts "撮合性能统计 #{args[:market_id] ? "(Market #{args[:market_id]})" : "(所有市场)"}"
      puts "="*60
      
      durations = logs.map(&:total_duration_ms).compact
      matched_counts = logs.map(&:matched_orders_count).compact
      
      puts "\n📊 耗时统计 (ms):"
      puts "  最小值: #{durations.min}"
      puts "  最大值: #{durations.max}"
      puts "  平均值: #{(durations.sum.to_f / durations.size).round(2)}"
      puts "  中位数: #{durations.sort[durations.size / 2]}"
      
      puts "\n📊 撮合数量统计:"
      puts "  总撮合次数: #{logs.count}"
      puts "  成功撮合: #{logs.where(status: 'success').count}"
      puts "  失败撮合: #{logs.where(status: 'failed').count}"
      puts "  取消撮合: #{logs.where(status: 'cancelled').count}"
      puts "  平均撮合订单数: #{matched_counts.any? ? (matched_counts.sum.to_f / matched_counts.size).round(2) : 0}"
      
      # 按市场分组统计
      if args[:market_id].nil?
        puts "\n📊 按市场分组:"
        market_stats = logs.group(:market_id).count
        market_stats.each do |market_id, count|
          success_rate = logs.where(market_id: market_id, status: 'success').count.to_f / count * 100
          puts "  Market #{market_id}: #{count} 次 (成功率 #{success_rate.round(1)}%)"
        end
      end
    else
      puts "\n❌ 没有找到撮合日志"
    end
    
    puts "\n" + "="*60
  end
end