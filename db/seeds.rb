# This file should ensure the existence of records required to run the application in every environment (production,
# development, test). The code here should be idempotent so that it can be executed at any point in every environment.
# The data can then be loaded with the bin/rails db:seed command (or created alongside the database with db:setup).
#
# Example:
#
#   ["Action", "Comedy", "Drama", "Horror"].each do |genre_name|
#     MovieGenre.find_or_create_by!(name: genre_name)
#   end

# 根据环境加载不同的种子数据
if Rails.env.test?
  # 测试环境使用专门的种子数据
  require_relative 'seeds/test_environment'
elsif Rails.env.development?
  # 开发环境种子数据
  puts "Loading development seed data..."
  
  # 创建默认用户
  default_user = User.find_or_create_by!(email: 'dev@puzzlex.io') do |user|
    user.password = 'password123'
    user.wallet_address = '0x' + '0' * 40
    user.username = 'DevUser'
    user.confirmed_at = Time.current
  end
  
  puts "Development seed data loaded!"
else
  # 生产环境不自动加载种子数据
  puts "Production environment - no automatic seed data"
end
