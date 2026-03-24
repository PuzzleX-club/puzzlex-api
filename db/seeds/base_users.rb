# 基础用户种子数据
# 只包含测试必需的源头用户数据，不包含业务状态

return unless Rails.env.test?

puts "👤 加载基础测试用户..."

# 测试用户基础数据
test_users = [
  {
    id: 'test_trader_001',
    address: '0x1234567890123456789012345678901234567890',
    nickname: '测试交易者1',
    role: 'active_trader',
    initial_eth_balance: '100.0', # 仅作为参考，实际余额通过业务逻辑设置
    private_key: ENV['TEST_PRIVATE_KEY_1'] || '0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80',
    description: '活跃交易用户，用于测试常规交易流程'
  },
  {
    id: 'test_trader_002', 
    address: '0xabcdefabcdefabcdefabcdefabcdefabcdefabcd',
    nickname: '测试交易者2',
    role: 'whale_trader',
    initial_eth_balance: '1000.0',
    private_key: ENV['TEST_PRIVATE_KEY_2'] || '0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d',
    description: '大户交易用户，用于测试大额交易和撮合'
  },
  {
    id: 'test_trader_003',
    address: '0x2345678901234567890123456789012345678901',
    nickname: '测试交易者3',
    role: 'casual_trader',
    initial_eth_balance: '50.0',
    private_key: ENV['TEST_PRIVATE_KEY_3'] || '0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a',
    description: '休闲交易用户，用于测试小额交易'
  },
  {
    id: 'test_collector_001',
    address: '0x3456789012345678901234567890123456789012',
    nickname: '测试收藏家1',
    role: 'collector',
    initial_eth_balance: '500.0',
    private_key: ENV['TEST_PRIVATE_KEY_4'] || '0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6',
    description: '收藏家用户，用于测试收藏和长期持有行为'
  }
]

# 创建测试用户（仅基础信息）
test_users.each do |user_data|
  user = Accounts::User.find_or_create_by(address: user_data[:address].downcase) do |u|
    u.address = user_data[:address].downcase
    puts "  ✅ 创建基础用户: #{user_data[:nickname]} (#{user_data[:address]})"
  end
  
  # 存储用户元数据（用于后续业务逻辑生成）
  user.update_columns(
    created_at: Time.current,
    updated_at: Time.current
  ) if user.persisted?
  
  puts "    📋 角色: #{user_data[:role]} | 描述: #{user_data[:description]}"
end

# 输出测试用户信息供后续使用
puts "\n📊 测试用户统计:"
puts "  - 总用户数: #{test_users.count}"
puts "  - 活跃交易者: #{test_users.count { |u| u[:role].include?('trader') }}"
puts "  - 收藏家: #{test_users.count { |u| u[:role] == 'collector' }}"

puts "\n🔑 私钥信息（仅测试环境）:"
test_users.each do |user_data|
  puts "  #{user_data[:nickname]}: #{user_data[:private_key]}"
end

puts "\n💡 下一步:"
puts "  - 使用TestAuthenticationGenerator生成认证数据"
puts "  - 使用TestBalanceGenerator初始化用户余额"
puts "  - 使用TestOrderGenerator创建订单数据"

puts "✅ 基础用户数据加载完成"