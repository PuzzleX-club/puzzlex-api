# Sidekiq Redis — consumes config.x.redis.sidekiq_url set in environments/*.rb
SIDEKIQ_REDIS_URL = Rails.application.config.x.redis.sidekiq_url

# 设置Sidekiq默认配置
Sidekiq.default_configuration.redis = { url: SIDEKIQ_REDIS_URL }

Sidekiq.configure_server do |config|
  config.redis = { url: SIDEKIQ_REDIS_URL }

  # Sidekiq 7.x 日志配置
  # 注意：config.logger 在某些上下文中可能不可用，需要检查
  if Rails.env.test?
    # 测试环境使用标准输出
    logger = ActiveSupport::Logger.new($stdout)
    logger.level = Logger::INFO
    config.logger = logger
  elsif config.respond_to?(:logger) && config.logger
    config.logger.level = Logger::WARN
  end

  # 添加trace_id到日志格式（如果logger可用）
  if config.respond_to?(:logger) && config.logger
    config.logger.formatter = proc do |severity, datetime, progname, msg|
      trace_id = Thread.current[:sidekiq_trace_id]
      if trace_id
        "[#{datetime.strftime('%Y-%m-%d %H:%M:%S')}] [#{severity}] [#{trace_id}] #{msg}\n"
      else
        "[#{datetime.strftime('%Y-%m-%d %H:%M:%S')}] [#{severity}] #{msg}\n"
      end
    end
  end

  # ========== 多实例切片：实例注册 ==========
  # 队列订阅由运行时启动参数或环境专用配置决定，此处只做实例注册
  registry = nil

  config.on(:startup) do
    Rails.logger.info "Sidekiq is starting with enhanced logging..."

    # 实例注册和心跳
    begin
      registry = Sidekiq::Cluster::InstanceRegistry.new
      registry.register
      registry.start_heartbeat_thread
      Rails.logger.info "[Sidekiq] 实例 #{registry.instance_id} 已注册并启动心跳"
    rescue => e
      Rails.logger.error "[Sidekiq] 实例注册失败: #{e.message}"
    end

    # ========== Leader选举服务 ==========
    if Rails.application.config.x.sidekiq_election.enabled
      begin
        Rails.logger.info "[Sidekiq] 启动Leader选举服务..."
        Sidekiq::Election::Monitoring::MetricsCollector.initialize_metrics
        Sidekiq::Election::Service.start
        if Rails.application.config.x.sidekiq_election.monitoring_enabled
          Sidekiq::Election::Monitoring.start_monitoring
        end
        Rails.logger.info "[Sidekiq] Leader选举服务已启动，状态: #{Sidekiq::Election::Service.status}"

        # 启动 Watchdog 守护线程（在 ElectionService 之后）
        Sidekiq::Election::Watchdog.start
        Rails.logger.info "[Sidekiq] ElectionWatchdog 已启动"
      rescue => e
        Rails.logger.error "[Sidekiq] Leader选举服务启动失败: #{e.class} - #{e.message}"
        Rails.logger.error e.backtrace.first(5).join("\n")
      end
    else
      Rails.logger.info "[Sidekiq] Leader选举服务已禁用"
    end

    # Catalog provider 启动时同步
    catalog_provider = Metadata::Catalog::ProviderRegistry.current
    if catalog_provider.enabled?
      begin
        Rails.logger.info "[Sidekiq] 启动时触发 Catalog 同步 (provider=#{catalog_provider.provider_key})..."
        CatalogSyncJob.perform_async
        Rails.logger.info "✅ CatalogSyncJob enqueued"
      rescue NameError => e
        Rails.logger.error "❌ CatalogSyncJob not found: #{e.message}"
      rescue => e
        Rails.logger.error "❌ CatalogSyncJob enqueue failed: #{e.class} - #{e.message}"
      end
    else
      Rails.logger.info "[Sidekiq] Catalog provider 已禁用，跳过启动同步 (provider=#{catalog_provider.provider_key})"
    end

    if Rails.env.production?
      begin
        Jobs::MarketData::Generation::KlineJob.perform_async
        Rails.logger.info "✅ KlineJob scheduled successfully"
      rescue NameError => e
        Rails.logger.error "❌ Failed to schedule KlineJob: #{e.message}"
      rescue => e
        Rails.logger.error "❌ Unexpected error: #{e.class} - #{e.message}"
      end
    end
  end

  config.on(:shutdown) do
    # 停止 Watchdog 守护线程（在 ElectionService 之前）
    if Rails.application.config.x.sidekiq_election.enabled
      begin
        Sidekiq::Election::Watchdog.stop
        Rails.logger.info "[Sidekiq] ElectionWatchdog 已停止"
      rescue => e
        Rails.logger.error "[Sidekiq] Watchdog 停止失败: #{e.message}"
      end
    end

    # 停止选举服务
    if Rails.application.config.x.sidekiq_election.enabled
      begin
        Sidekiq::Election::Service.stop
        Rails.logger.info "[Sidekiq] Leader选举服务已停止"
      rescue => e
        Rails.logger.error "[Sidekiq] 选举服务停止失败: #{e.message}"
      end
    end

    # 实例注销
    if registry
      begin
        registry.stop_heartbeat_thread
        registry.deregister
        Rails.logger.info "[Sidekiq] 实例 #{registry.instance_id} 已注销"
      rescue => e
        Rails.logger.error "[Sidekiq] 实例注销失败: #{e.message}"
      end
    end
  end
end

Sidekiq.configure_client do |config|
  config.redis = { url: SIDEKIQ_REDIS_URL }
end

Sidekiq.strict_args!(false)
