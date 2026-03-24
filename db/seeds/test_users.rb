# 测试用户基础数据
# 生成时间: 2025-07-12 15:56:02

return unless Rails.env.test?

puts '👤 加载测试用户数据...'

test_users_data = [
  {
    address: '0x1234567890123456789012345678901234567890',
    # 角色: active_trader - 用于测试常规交易流程
  },
  {
    address: '0xabcdefabcdefabcdefabcdefabcdefabcdefabcd',
    # 角色: whale_trader - 用于测试大额交易和撮合
  },
  {
    address: '0x2345678901234567890123456789012345678901',
    # 角色: casual_trader - 用于测试小额交易
  },
  {
    address: '0x3456789012345678901234567890123456789012',
    # 角色: collector - 用于测试收藏和长期持有
  },
  {
    address: '0x4567890123456789012345678901234567890123',
    # 角色: material_trader - 用于测试材料类物品交易
  }
]

puts '💾 开始创建测试用户...'

test_users_data.each_with_index do |user_data, index|
  user = Accounts::User.find_or_create_by!(address: user_data[:address]) do |u|
    u.created_at = Time.current - rand(30).days
    u.updated_at = Time.current
    puts "  ✅ 用户 #{index + 1}: #{user_data[:address]}"
  end
end

puts "✅ 测试用户创建完成: #{test_users_data.count} 个用户"

# 输出用户信息供测试使用
puts "\n📋 测试用户列表:"
puts "  1. 活跃交易者 (active_trader): 0x1234567890123456789012345678901234567890"
puts "  2. 大户投资者 (whale_trader): 0xabcdefabcdefabcdefabcdefabcdefabcdefabcd"
puts "  3. 休闲玩家 (casual_trader): 0x2345678901234567890123456789012345678901"
puts "  4. 装备收藏家 (collector): 0x3456789012345678901234567890123456789012"
puts "  5. 材料商人 (material_trader): 0x4567890123456789012345678901234567890123"
