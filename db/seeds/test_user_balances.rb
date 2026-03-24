# 测试用户余额数据
# 生成时间: 2025-07-12 15:58:58
# 数据量: 10 条余额记录

return unless Rails.env.test?

puts '💰 加载测试用户余额数据...'

# 检查UserBalance模型
unless defined?(UserBalance)
  puts '⚠️  UserBalance模型未定义，跳过余额数据加载'
  return
end

balance_data = [
  {
    user_address: '0x1234567890123456789012345678901234567890',
    item_id: 90001,
    balance: 7,
    locked_balance: 0,
    updated_at: Time.current
  },
  {
    user_address: '0x1234567890123456789012345678901234567890',
    item_id: 90002,
    balance: 5,
    locked_balance: 0,
    updated_at: Time.current
  },
  {
    user_address: '0xabcdefabcdefabcdefabcdefabcdefabcdefabcd',
    item_id: 90001,
    balance: 12,
    locked_balance: 0,
    updated_at: Time.current
  },
  {
    user_address: '0xabcdefabcdefabcdefabcdefabcdefabcdefabcd',
    item_id: 90002,
    balance: 5,
    locked_balance: 0,
    updated_at: Time.current
  },
  {
    user_address: '0x2345678901234567890123456789012345678901',
    item_id: 90001,
    balance: 2,
    locked_balance: 0,
    updated_at: Time.current
  },
  {
    user_address: '0x2345678901234567890123456789012345678901',
    item_id: 90002,
    balance: 1,
    locked_balance: 0,
    updated_at: Time.current
  },
  {
    user_address: '0x3456789012345678901234567890123456789012',
    item_id: 90001,
    balance: 17,
    locked_balance: 0,
    updated_at: Time.current
  },
  {
    user_address: '0x3456789012345678901234567890123456789012',
    item_id: 90002,
    balance: 19,
    locked_balance: 0,
    updated_at: Time.current
  },
  {
    user_address: '0x4567890123456789012345678901234567890123',
    item_id: 90001,
    balance: 5,
    locked_balance: 0,
    updated_at: Time.current
  },
  {
    user_address: '0x4567890123456789012345678901234567890123',
    item_id: 90002,
    balance: 5,
    locked_balance: 0,
    updated_at: Time.current
  }
]

puts '💾 开始保存用户余额数据...'

balance_data.each_with_index do |data, index|
  UserBalance.find_or_create_by!(
    user_address: data[:user_address],
    item_id: data[:item_id]
  ) do |balance|
    balance.assign_attributes(data)
    puts "  ✅ 余额 #{index + 1}/#{balance_data.count}: 用户#{data[:user_address][-6..-1]} 物品#{data[:item_id]} = #{data[:balance]}" if (index + 1) % 10 == 0
  end
end

puts "✅ 用户余额数据加载完成: #{balance_data.count} 条记录"

# 输出余额统计
puts "\n📊 余额统计:"
balance_summary = balance_data.group_by { |b| b[:user_address] }
balance_summary.each do |address, balances|
  total_balance = balances.sum { |b| b[:balance] }
  puts "  用户 #{address[-6..-1]}: #{balances.count} 种物品, 总计 #{total_balance} 个"
end
