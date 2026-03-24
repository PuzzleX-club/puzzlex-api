# frozen_string_literal: true

# 测试环境专用种子数据
# 用于测试控制API的环境重置

puts "Loading test environment seed data..."

# 清理现有数据
ActiveRecord::Base.connection.execute('SET FOREIGN_KEY_CHECKS = 0')
%w[events transactions order_items orders api_keys users collections tokens].each do |table|
  ActiveRecord::Base.connection.execute("TRUNCATE TABLE #{table}")
end
ActiveRecord::Base.connection.execute('SET FOREIGN_KEY_CHECKS = 1')

# 创建测试用户
test_users = []
5.times do |i|
  user = User.create!(
    email: "test#{i+1}@puzzlex.io",
    password: 'password123',
    wallet_address: "0x#{'%040x' % (i+1)}",
    username: "TestUser#{i+1}",
    confirmed_at: Time.current
  )
  
  # 为每个用户创建API密钥
  user.api_keys.create!(
    key: SecureRandom.hex(32),
    name: "Test API Key #{i+1}"
  )
  
  test_users << user
  puts "Created test user: #{user.username}"
end

# 创建测试集合
collections = []
3.times do |i|
  collection = Collection.create!(
    name: "Test Collection #{i+1}",
    contract_address: "0x#{'%040x' % (100+i)}",
    chain_id: 1,
    metadata: {
      description: "Test collection for automated testing",
      image: "https://example.com/collection#{i+1}.png"
    }
  )
  collections << collection
  puts "Created test collection: #{collection.name}"
end

# 创建一些初始订单（不同状态）
order_types = ['listing', 'offer']
statuses = ['pending', 'active', 'matched', 'cancelled', 'expired']

20.times do |i|
  order = Order.create!(
    user: test_users[i % test_users.length],
    token_id: rand(1..100),
    collection: collections[i % collections.length],
    price: rand(10.0..1000.0).round(2),
    order_type: order_types[i % 2],
    status: i < 10 ? 'pending' : statuses[rand(statuses.length)],
    expires_at: i < 5 ? Time.current + rand(1..24).hours : nil,
    metadata: {
      test_order: true,
      batch: i / 5
    }
  )
  puts "Created test order ##{order.id} - #{order.order_type} - #{order.status}"
end

# 创建一些匹配的订单对（用于测试撮合）
3.times do |i|
  token_id = 1000 + i
  price = (100 * (i + 1)).to_f
  
  # 卖单
  sell_order = Order.create!(
    user: test_users[0],
    token_id: token_id,
    collection: collections[0],
    price: price,
    order_type: 'listing',
    status: 'active'
  )
  
  # 买单
  buy_order = Order.create!(
    user: test_users[1],
    token_id: token_id,
    collection: collections[0],
    price: price,
    order_type: 'offer',
    status: 'active'
  )
  
  puts "Created matching pair: Token #{token_id} at #{price}"
end

# 创建一些交易记录
5.times do |i|
  transaction = Transaction.create!(
    from_user: test_users[i % test_users.length],
    to_user: test_users[(i + 1) % test_users.length],
    order: Order.where(status: 'matched').sample,
    transaction_hash: "0x#{'%064x' % rand(2**256)}",
    status: 'completed',
    amount: rand(10.0..500.0).round(2),
    created_at: Time.current - rand(1..30).days
  )
  puts "Created test transaction: #{transaction.transaction_hash[0..10]}..."
end

puts "Test environment seed data loaded successfully!"
puts "Summary:"
puts "  - Users: #{User.count}"
puts "  - Collections: #{Collection.count}"
puts "  - Orders: #{Order.count}"
puts "  - Transactions: #{Transaction.count}"