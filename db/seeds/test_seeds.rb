# 测试环境种子数据
# 仅在测试环境执行

return unless Rails.env.test?

puts "🌱 开始初始化测试环境数据..."

# 创建测试用户
test_user_address = "0x1234567890123456789012345678901234567890"
test_user = Accounts::User.find_or_create_by(address: test_user_address.downcase) do |user|
  user.address = test_user_address.downcase
  puts "  ✅ 创建测试用户: #{user.address}"
end

# 创建额外的测试用户用于匹配测试
test_user_2_address = "0xabcdefabcdefabcdefabcdefabcdefabcdefabcd"
test_user_2 = Accounts::User.find_or_create_by(address: test_user_2_address.downcase) do |user|
  user.address = test_user_2_address.downcase
  puts "  ✅ 创建测试用户2: #{user.address}"
end

# 测试NFT合约数据
test_nft_contract = "0x9EF5B0Da15C84177164aD95F6C06FA787bDC5A4e"
test_token_ids = ["1", "2", "3", "100", "1000"]

puts "  📋 测试数据准备完成:"
puts "    - 测试用户1: #{test_user.address}"
puts "    - 测试用户2: #{test_user_2.address}" 
puts "    - NFT合约: #{test_nft_contract}"
puts "    - 测试Token IDs: #{test_token_ids.join(', ')}"

# 清理现有测试订单（如果有）
deleted_orders = Trading::Order.where(offerer: [test_user.address, test_user_2.address]).delete_all
puts "  🧹 清理了 #{deleted_orders} 个旧的测试订单"

puts "🎯 测试环境数据初始化完成！"
puts ""
puts "📡 可用的测试支撑端点（独立服务，默认端口 3301）："
puts "  GET    /internal/test-support/health_check        - 健康检查"
puts "  POST   /internal/test-support/get_test_token      - 获取测试认证token"
puts "  POST   /internal/test-support/setup               - 初始化测试数据"
puts "  GET    /internal/test-support/get_orders          - 获取订单列表"
puts "  PATCH  /internal/test-support/:id/update_order    - 更新订单"
puts "  DELETE /internal/test-support/:id/delete_order    - 删除订单"
puts "  POST   /internal/test-support/wait_for_jobs       - 等待异步任务完成"
puts "  DELETE /internal/test-support/cleanup             - 清理测试数据"
puts ""
puts "🔧 环境配置："
puts "  - Sidekiq模式: #{Rails.application.config.active_job.queue_adapter}"
puts "  - 数据库: #{Rails.application.config.database_configuration[Rails.env]['database']}"
puts "  - Redis: redis://localhost:6381/0 (测试专用)"
