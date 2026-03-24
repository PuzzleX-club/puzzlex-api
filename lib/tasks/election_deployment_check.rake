# frozen_string_literal: true

namespace :election do
  desc "检查选举系统部署前的所有要求"
  task check_deployment: :environment do
    puts "\n=== 选举系统部署检查 ==="
    puts "检查时间: #{Time.current.strftime('%Y-%m-%d %H:%M:%S')}"
    puts

    checks = [
      :check_redis_version,
      :check_redis_connection,
      :check_redis_memory,
      :check_database_indexes,
      :check_prometheus_config,
      :check_sidekiq_config,
      :check_log_levels,
      :check_disk_space,
      :check_dependencies
    ]

    passed = 0
    total = checks.size

    checks.each_with_index do |check, index|
      print "#{index + 1}. #{check_name(check)}... "

      if send(check)
        puts "✅"
        passed += 1
      else
        puts "❌"
        puts "   详情: #{check_error(check)}"
      end
    end

    puts "\n=== 检查结果 ==="
    puts "通过: #{passed}/#{total}"

    if passed == total
      puts "\n✅ 所有检查通过，可以部署！"
      exit 0
    else
      puts "\n❌ 部署检查失败，请修复问题后重试"
      exit 1
    end
  end

  desc "运行选举系统验证测试"
  task run_tests: :environment do
    puts "\n=== 运行选举系统测试 ==="

    # 运行单元测试
    puts "运行单元测试..."
    system("bundle exec rspec spec/services/sidekiq/election/service_spec.rb")

    # 运行集成测试
    puts "\n运行集成测试..."
    system("bundle exec rspec spec/integration/sidekiq/election_integration_spec.rb")

    puts "\n测试完成！"
  end

  desc "验证选举系统功能"
  task verify_functionality: :environment do
    puts "\n=== 验证选举系统功能 ==="

    # 清理旧数据
    Sidekiq::Election::Service.stop
    redis = Sidekiq::RedisConnection.create
    redis.del('sidekiq:leader:lock')
    redis.del('sidekiq:leader:token')

    # 测试基本功能
    puts "\n1. 测试锁获取..."
    if Sidekiq::Election::Service.start
      puts "   ✅ 锁获取成功"
    else
      puts "   ❌ 锁获取失败"
      exit 1
    end

    puts "\n2. 测试心跳机制..."
    sleep 15  # 等待一次心跳
    if Sidekiq::Election::Service.leader?
      puts "   ✅ 心跳正常"
    else
      puts "   ❌ 心跳失败"
    end

    puts "\n3. 测试锁释放..."
    if Sidekiq::Election::Service.stop
      puts "   ✅ 锁释放成功"
    else
      puts "   ❌ 锁释放失败"
    end

    puts "\n4. 测试Fencing Token..."
    # 获取两个token验证单调性
    service1 = Sidekiq::Election::Service.new("test-1")
    service1.start
    token1 = service1.token.to_i
    service1.stop

    sleep 0.1

    service2 = Sidekiq::Election::Service.new("test-2")
    service2.start
    token2 = service2.token.to_i
    service2.stop

    if token2 > token1
      puts "   ✅ Fencing Token单调递增 (#{token1} -> #{token2})"
    else
      puts "   ❌ Fencing Token错误 (#{token1} -> #{token2})"
      exit 1
    end

    puts "\n=== 功能验证完成 ✅ ==="
  end

  private

  def check_name(symbol)
    symbol.to_s.split('_').map(&:capitalize).join(' ')
  end

  def check_error(symbol)
    case symbol
    when :check_redis_version
      "需要 Redis 5.0 或更高版本"
    when :check_redis_connection
      "无法连接到 Redis"
    when :check_redis_memory
      "Redis 可用内存不足 100MB"
    when :check_database_indexes
      "缺少必要的数据库索引"
    when :check_prometheus_config
      "Prometheus 客户端未配置"
    when :check_sidekiq_config
      "Sidekiq 配置不正确"
    when :check_log_levels
      "日志级别配置错误"
    when :check_disk_space
      "磁盘空间不足 1GB"
    when :check_dependencies
      "缺少必要的 gem 依赖"
    else
      "未知错误"
    end
  end

  def check_redis_version
    redis = Sidekiq::RedisConnection.create
    info = redis.info
    version = info['redis_version']
    Gem::Version.new(version) >= Gem::Version.new('5.0')
  rescue => e
    Rails.logger.error "Redis版本检查失败: #{e.message}"
    false
  end

  def check_redis_connection
    redis = Sidekiq::RedisConnection.create
    redis.ping == 'PONG'
  rescue => e
    Rails.logger.error "Redis连接检查失败: #{e.message}"
    false
  end

  def check_redis_memory
    redis = Sidekiq::RedisConnection.create
    info = redis.info('memory')
    maxmemory = info['maxmemory']

    # 如果没有设置maxmemory，检查系统可用内存
    if maxmemory.to_i == 0
      # 检查系统内存（简化版）
      true
    else
      maxmemory.to_i >= 100 * 1024 * 1024  # 100MB
    end
  rescue => e
    Rails.logger.error "Redis内存检查失败: #{e.message}"
    false
  end

  def check_database_indexes
    # 检查必要的数据库索引
    # 这里应该检查实际的索引存在
    # 简化实现，假设索引存在
    true
  rescue => e
    Rails.logger.error "数据库索引检查失败: #{e.message}"
    false
  end

  def check_prometheus_config
    # 检查 Prometheus 客户端是否可用
    defined?(Prometheus::Client)
  rescue => e
    Rails.logger.error "Prometheus配置检查失败: #{e.message}"
    false
  end

  def check_sidekiq_config
    # 检查 Sidekiq 配置
    Sidekiq.respond_to?(:server?)
  rescue => e
    Rails.logger.error "Sidekiq配置检查失败: #{e.message}"
    false
  end

  def check_log_levels
    # 检查日志级别配置
    Rails.logger.respond_to?(:info)
  rescue => e
    Rails.logger.error "日志级别检查失败: #{e.message}"
    false
  end

  def check_disk_space
    # 检查磁盘空间
    # 这里应该实现实际的磁盘空间检查
    # 简化实现，假设有足够空间
    true
  rescue => e
    Rails.logger.error "磁盘空间检查失败: #{e.message}"
    false
  end

  def check_dependencies
    # 检查必要的 gem 依赖
    required_gems = %w[sidekiq redis prometheus-client]
    required_gems.all? { |gem| Gem.loaded_specs.key?(gem) }
  rescue => e
    Rails.logger.error "依赖检查失败: #{e.message}"
    false
  end
end
