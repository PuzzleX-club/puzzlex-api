# frozen_string_literal: true

# This file is copied to spec/ when you run 'rails generate rspec:install'
require 'spec_helper'
ENV['RAILS_ENV'] ||= 'test'

# 加载 .env.test 环境变量（在 Rails 环境加载之前）
env_file = File.expand_path('../../.env.test', __FILE__)
if File.exist?(env_file)
  File.readlines(env_file).each do |line|
    line = line.strip
    next if line.empty? || line.start_with?('#')

    key, value = line.split('=', 2)
    ENV[key] ||= value if key && value
  end
end

require_relative '../config/environment'
# Prevent database truncation if the environment is production
abort('The Rails environment is running in production mode!') if Rails.env.production?
require 'rspec/rails'

# 加载 Faker
require 'faker'

# 加载所有 support 文件
Dir[Rails.root.join('spec', 'support', '**', '*.rb')].each { |f| require f }

# Checks for pending migrations and applies them before tests are run.
# begin
#   ActiveRecord::Migration.maintain_test_schema!
# rescue ActiveRecord::PendingMigrationError => e
#   puts e.to_s.strip
#   exit 1
# end

RSpec.configure do |config|
  # Remove this line if you're not using ActiveRecord or ActiveRecord fixtures
  # Note: Using singular fixture_path for Rails 7.1 compatibility
  # Will need to change to fixture_paths when upgrading to Rails 7.2+
  config.fixture_path = Rails.root.join('spec/fixtures')

  # If you're not using ActiveRecord, or you'd prefer not to run each of your
  # examples within a transaction, remove the following line or assign false
  # instead of true.
  config.use_transactional_fixtures = true

  # RSpec Rails can automatically mix in different behaviours to your tests
  # based on their file location
  config.infer_spec_type_from_file_location!

  # Filter lines from Rails gems in backtraces.
  config.filter_rails_from_backtrace!

  # ============================================
  # FactoryBot 配置
  # ============================================
  config.include FactoryBot::Syntax::Methods

  # ============================================
  # 认证辅助
  # ============================================
  config.include AuthHelper, type: :request

  # ============================================
  # Shoulda Matchers 配置
  # ============================================
  Shoulda::Matchers.configure do |shoulda_config|
    shoulda_config.integrate do |with|
      with.test_framework :rspec
      with.library :rails
    end
  end

  # ============================================
  # 测试执行配置
  # ============================================

  # 启用随机顺序执行
  config.order = :random
  Kernel.srand config.seed

  # 启用 focus 过滤（使用 :focus 标记只运行特定测试）
  config.filter_run_when_matching :focus

  # 保存测试状态，支持 --only-failures 选项
  config.example_status_persistence_file_path = 'spec/examples.txt'

  # 输出最慢的 10 个测试
  config.profile_examples = 10 if ENV['PROFILE']

  # ============================================
  # 清理配置
  # ============================================

  # 每个测试前重置 Faker
  config.before(:each) do
    Faker::UniqueGenerator.clear
  end

  # ============================================
  # Sidekiq 测试配置
  # ============================================

  # 默认使用 fake 模式（Jobs 入队但不执行）
  config.before(:each) do
    Sidekiq::Testing.fake! if defined?(Sidekiq::Testing)
  end

  # 标记为 :inline_sidekiq 的测试会同步执行 Jobs
  # 用于需要验证完整业务流程的集成测试
  config.around(:each, :inline_sidekiq) do |example|
    if defined?(Sidekiq::Testing)
      Sidekiq::Testing.inline! do
        example.run
      end
    else
      example.run
    end
  end

  # 标记为 :disable_sidekiq 的测试完全禁用 Sidekiq
  config.around(:each, :disable_sidekiq) do |example|
    if defined?(Sidekiq::Testing)
      Sidekiq::Testing.disable! do
        example.run
      end
    else
      example.run
    end
  end

  # ============================================
  # 元数据配置
  # ============================================

  # 为所有 request spec 添加 JSON 请求头
  config.before(:each, type: :request) do
    # 默认使用 JSON 格式
  end
end
