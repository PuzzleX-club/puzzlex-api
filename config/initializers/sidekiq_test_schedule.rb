# frozen_string_literal: true

# 在测试环境中加快 Sidekiq 调度器的执行频率
if Rails.env.test?
  require 'sidekiq'
  require 'sidekiq-scheduler'

  Rails.application.config.after_initialize do
    begin
      # 获取当前的调度配置
      schedule = Sidekiq.get_schedule || {}

      test_schedule_overrides = {
        'matching_order_match_dispatcher' => {
          'cron' => '*/2 * * * * *',
          'description' => '测试环境：每2秒扫描订单匹配'
        },
        'matching_over_match_dispatch' => {
          'cron' => '0 */1 * * * *',
          'description' => '测试环境：每1分钟检测超匹配订单'
        },
        'market_data_generation_kline' => {
          'cron' => '*/10 * * * * *',
          'description' => '测试环境：每10秒生成K线'
        },
        'market_data_generation_aggregate' => {
          'cron' => '*/10 * * * * *',
          'description' => '测试环境：快速聚合24h行情'
        },
        'market_data_broadcast_snapshot' => {
          'cron' => '*/10 * * * * *',
          'description' => '测试环境：快速广播MARKET@1440'
        },
        'market_data_sync_registry' => {
          'cron' => '0 * * * * *',
          'description' => '测试环境：每分钟同步市场数据'
        },
        'market_data_maintenance_summary_refresh' => {
          'cron' => '*/1 * * * * *',
          'description' => '测试环境：每秒刷新 dirty 市场摘要'
        },
        'indexer_event_collector' => {
          'cron' => '*/2 * * * * *',
          'description' => '测试环境：每2秒采集链上事件'
        },
        'indexer_instance_metadata_scanner' => {
          'cron' => '*/10 * * * * *',
          'description' => '测试环境：每10秒扫描实例元数据'
        },
        'merkle_generate_tree' => {
          'cron' => '0 */10 * * * *',
          'description' => '测试环境：每10分钟生成Merkle树'
        },
        'merkle_tree_guardian' => {
          'cron' => '0 * * * * *',
          'description' => '测试环境：每分钟检查Merkle树'
        }
      }

      test_schedule_overrides.each do |job_name, job_config|
        next unless schedule[job_name]

        schedule[job_name]['cron'] = job_config['cron']
        schedule[job_name]['description'] = job_config['description']
      end

      schedule.each do |name, config|
        Sidekiq.set_schedule(name, config)
      end

      Rails.logger.info "🚀 测试环境 Sidekiq 调度器已配置为快速模式"
      Rails.logger.info "📋 当前调度配置："
      schedule.each do |name, config|
        Rails.logger.info "  - #{name}: #{config['cron']} (#{config['description'] || '无描述'})"
      end
    rescue RedisClient::CannotConnectError, Redis::CannotConnectError => e
      Rails.logger.warn "⚠️  Redis 连接失败，跳过 Sidekiq 测试调度配置: #{e.message}"
      Rails.logger.warn "💡 请确保 Redis 测试服务正在运行 (端口 6381)"
    rescue => e
      Rails.logger.error "❌ Sidekiq 测试调度配置失败: #{e.message}"
      Rails.logger.error e.backtrace.first(5).join("\n")
    end
  end
end
