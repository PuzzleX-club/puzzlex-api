require "active_support/core_ext/integer/time"

# The test environment is used exclusively to run your application's
# test suite. You never need to work with it otherwise. Remember that
# your test database is "scratch space" for the test suite and is wiped
# and recreated between test runs. Don't rely on the data there!

Rails.application.configure do
  # Settings specified here will take precedence over those in config/application.rb.

  # While tests run files are not watched, reloading is not necessary.
  config.enable_reloading = false

  # Eager loading loads your entire application. When running a single test locally,
  # this is usually not necessary, and can slow down your test suite. However, it's
  # recommended that you enable it in continuous integration systems to ensure eager
  # loading is working properly before deploying your code.
  config.eager_load = ENV["CI"].present?

  # Configure public file server for tests with Cache-Control for performance.
  config.public_file_server.enabled = true
  config.public_file_server.headers = {
    "Cache-Control" => "public, max-age=#{1.hour.to_i}"
  }

  # Show full error reports and disable caching.
  config.consider_all_requests_local = true
  config.action_controller.perform_caching = false

  # Redis URL 统一入口
  config.x.redis.default_url = ENV.fetch('REDIS_URL', 'redis://localhost:6381/0')
  config.x.redis.sidekiq_url = ENV.fetch('SIDEKIQ_REDIS_URL', config.x.redis.default_url.sub(/\/\d+$/, '/1'))
  config.x.redis.cache_url   = config.x.redis.default_url
  config.x.redis.cable_url   = config.x.redis.sidekiq_url

  # 根据环境变量决定缓存策略：默认null_store保证测试隔离性
  if ENV['ENABLE_CACHE_TESTING'] == 'true'
    config.cache_store = :memory_store
  else
    config.cache_store = :null_store
  end

  # Render exception templates for rescuable exceptions and raise for other exceptions.
  config.action_dispatch.show_exceptions = :rescuable

  # Disable request forgery protection in test environment.
  config.action_controller.allow_forgery_protection = false

  # Print deprecation notices to the stderr.
  config.active_support.deprecation = :stderr

  # Raise exceptions for disallowed deprecations.
  config.active_support.disallowed_deprecation = :raise

  # Tell Active Support which deprecation messages to disallow.
  config.active_support.disallowed_deprecation_warnings = []

  # Raises error for missing translations.
  # config.i18n.raise_on_missing_translations = true

  # Annotate rendered view with file names.
  # config.action_view.annotate_rendered_view_with_filenames = true

  # Raise error when a before_action's only/except options reference missing actions
  config.action_controller.raise_on_missing_callback_actions = true
  # 测试环境同样承载 numeric(78,0) wei 值，关闭 int64 宽度保护以避免误报。
  ActiveRecord.raise_int_wider_than_64bit = false

  # 日志配置优化
  if ENV['RAILS_LOG_TO_STDOUT'].present?
    logger           = ActiveSupport::Logger.new(STDOUT)
    logger.formatter = config.log_formatter
    config.logger    = ActiveSupport::TaggedLogging.new(logger)
  end

  # 设置日志级别（默认info，可通过环境变量调整）
  config.log_level = ENV.fetch('RAILS_LOG_LEVEL', 'info').to_sym

  # 控制ActiveRecord日志（减少SQL查询日志噪音）
  config.active_record.verbose_query_logs = false

  # ActiveJob配置 - 支持端到端集成测试
  # 默认同步执行，可通过环境变量切换为异步模式
  if ENV['ASYNC_JOBS'] == 'true'
    config.active_job.queue_adapter = :sidekiq
    # 注意：这里不能使用Rails.logger，因为此时还没有初始化
    puts "测试环境: 使用异步Sidekiq队列 (ASYNC_JOBS=true)" if defined?(Rails::Server)
  else
    config.active_job.queue_adapter = :inline
    # 注意：这里不能使用Rails.logger，因为此时还没有初始化
    puts "测试环境: 使用同步执行队列 (ASYNC_JOBS未设置)" if defined?(Rails::Server)
  end

  # ActionCable配置 - 测试环境WebSocket支持
  config.action_cable.mount_path = "/cable"
  config.action_cable.url = "ws://localhost:3001/cable"
  config.action_cable.allowed_request_origins = [
    'http://localhost:3001',
    'http://localhost:5173', 
    /http:\/\/127\.0\.0\.1:\d+/,
    /http:\/\/localhost:\d+/
  ]
  config.action_cable.disable_request_forgery_protection = true

  config.x.log_collector = ActiveSupport::OrderedOptions.new
  config.x.log_collector.retention_days = 7
  config.x.log_collector.max_consecutive_failures = ENV.fetch('LOG_COLLECTOR_MAX_CONSECUTIVE_FAILURES', '10').to_i
  config.x.log_collector.error_backoff_max = ENV.fetch('LOG_COLLECTOR_ERROR_BACKOFF_MAX', '30').to_f
  config.x.log_collector.catchup_threshold = ENV.fetch('LOG_COLLECTOR_CATCHUP_THRESHOLD', '1000').to_i
  config.x.log_collector.rps = ENV.fetch('LOG_COLLECTOR_RPS', '5').to_f
  config.x.log_collector.catchup_rps = ENV.fetch('LOG_COLLECTOR_CATCHUP_RPS', '10').to_f

  # 区块链配置（必须在 .env.test 中提供）
  config.x.blockchain.rpc_url = ENV.fetch('BLOCKCHAIN_RPC_URL')
  config.x.blockchain.chain_id = ENV.fetch('CHAIN_ID').to_i
  config.x.blockchain.seaport_contract_address = ENV.fetch('SEAPORT_CONTRACT_ADDRESS')
  config.x.blockchain.nft_contract_address = ENV.fetch('NFT_CONTRACT_ADDRESS')
  config.x.blockchain.erc20_contract_address = ENV.fetch('ERC20_CONTRACT_ADDRESS')
  config.x.blockchain.zone_contract_address = ENV.fetch('ZONE_CONTRACT_ADDRESS')
  config.x.blockchain.platform_contract_address = ENV.fetch('PLATFORM_CONTRACT_ADDRESS')
  config.x.blockchain.royalty_contract_address = ENV.fetch('ROYALTY_CONTRACT_ADDRESS')
  config.x.blockchain.event_listener_genesis_block = ENV.fetch('EVENT_LISTENER_GENESIS_BLOCK', '0').to_i

  # 撮合 spread 分配配置（集中环境配置，业务层禁止直接读取 ENV）
  config.x.match_spread = ActiveSupport::OrderedOptions.new
  config.x.match_spread.platform_bps = ENV.fetch('MATCH_SPREAD_PLATFORM_BPS', '5000').to_i
  config.x.match_spread.royalty_bps = ENV.fetch('MATCH_SPREAD_ROYALTY_BPS', '900').to_i
  config.x.match_spread.seller_bps = ENV.fetch('MATCH_SPREAD_SELLER_BPS', '0').to_i

  # 撮合日志降噪与写入策略（集中环境配置，业务层禁止直接读取 ENV）
  config.x.match_logging = ActiveSupport::OrderedOptions.new
  config.x.match_logging.enabled = ENV.fetch('MATCH_LOGGING_ENABLED', 'true') == 'true'
  config.x.match_logging.persist_started = ENV.fetch('MATCH_LOGGING_PERSIST_STARTED', 'false') == 'true'
  config.x.match_logging.store_order_hashes = ENV.fetch('MATCH_LOGGING_STORE_ORDER_HASHES', 'false') == 'true'
  config.x.match_logging.max_order_hashes_per_operation = ENV.fetch('MATCH_LOGGING_MAX_ORDER_HASHES', '6').to_i
  config.x.match_logging.max_queue_operations = ENV.fetch('MATCH_LOGGING_MAX_QUEUE_OPERATIONS', '60').to_i
  config.x.match_logging.cancelled_noop_sampling_rate = ENV.fetch('MATCH_LOGGING_CANCELLED_NOOP_SAMPLING_RATE', '0.1').to_f

  # 撮合引擎开关配置（集中环境配置，业务层禁止直接读取 ENV）
  config.x.match_engine = ActiveSupport::OrderedOptions.new
  config.x.match_engine.mxn_enabled = ENV.fetch('MATCH_ENGINE_MXN_ENABLED', 'true') == 'true'
  config.x.match_engine.max_layers = ENV.fetch('CES_MAX_LAYERS', '5').to_i
  config.x.match_engine.max_targets = ENV.fetch('CES_MAX_TARGETS', '8').to_i
  config.x.match_engine.flow_budget = ENV.fetch('CES_FLOW_BUDGET', '20').to_i
  config.x.match_engine.round_timeout_ms = ENV.fetch('CES_ROUND_TIMEOUT_MS', '500').to_i
  config.x.match_engine.max_bitset_size = ENV.fetch('CES_MAX_BITSET_SIZE', '10000').to_i
  config.x.match_engine.window_size = ENV.fetch('CES_WINDOW_SIZE', '150').to_i
  config.x.match_engine.max_rounds = ENV.fetch('CES_MAX_ROUNDS', '10').to_i
  config.x.match_engine.total_timeout_ms = ENV.fetch('CES_TOTAL_TIMEOUT_MS', '3000').to_i

  # 撮合调度器配置（集中环境配置，业务层禁止直接读取 ENV）
  config.x.match_scheduler = ActiveSupport::OrderedOptions.new
  config.x.match_scheduler.worker_timeout_sec   = ENV.fetch('MATCH_SCHEDULER_WORKER_TIMEOUT_SEC', '5').to_i
  config.x.match_scheduler.lock_ttl_sec         = ENV.fetch('MATCH_SCHEDULER_LOCK_TTL_SEC', '10').to_i
  config.x.match_scheduler.loop_budget_sec      = ENV.fetch('MATCH_SCHEDULER_LOOP_BUDGET_SEC', '3').to_i
  config.x.match_scheduler.followup_delay_sec   = ENV.fetch('MATCH_SCHEDULER_FOLLOWUP_DELAY_SEC', '1').to_f
  config.x.match_scheduler.waiting_delay_sec    = ENV.fetch('MATCH_SCHEDULER_WAITING_DELAY_SEC', '10').to_i
  config.x.match_scheduler.dedup_ttl_sec        = ENV.fetch('MATCH_SCHEDULER_DEDUP_TTL_SEC', '2').to_i

  # CatalogProvider 配置已迁移至 config/initializers/catalog_provider.rb

  # Sidekiq选举系统配置（测试环境）
  config.x.sidekiq_election = ActiveSupport::OrderedOptions.new
  config.x.sidekiq_election.enabled = ENV.fetch('SIDEKIQ_ELECTION_ENABLED', 'false') == 'true'  # 测试环境默认禁用
  config.x.sidekiq_election.heartbeat_interval = ENV.fetch('SIDEKIQ_ELECTION_HEARTBEAT_INTERVAL', '5').to_i  # 测试环境缩短心跳间隔
  config.x.sidekiq_election.heartbeat_jitter = ENV.fetch('SIDEKIQ_ELECTION_HEARTBEAT_JITTER', '1').to_i
  config.x.sidekiq_election.ttl_seconds = ENV.fetch('SIDEKIQ_ELECTION_TTL_SECONDS', '20').to_i  # 测试环境缩短TTL
  config.x.sidekiq_election.max_consecutive_failures = ENV.fetch('SIDEKIQ_ELECTION_MAX_FAILURES', '2').to_i
  config.x.sidekiq_election.redis_url = config.x.redis.default_url
  config.x.sidekiq_election.log_level = ENV.fetch('SIDEKIQ_ELECTION_LOG_LEVEL', 'debug')
  config.x.sidekiq_election.monitoring_enabled = ENV.fetch('SIDEKIQ_ELECTION_MONITORING_ENABLED', 'false') == 'true'  # 测试环境禁用监控
  config.x.sidekiq_election.static_leader_index = ENV.fetch('SIDEKIQ_STATIC_LEADER_INDEX', '0').to_i  # 静态 Leader 模式：INDEX=0 为 Leader
  config.x.sidekiq_election.watchdog_enabled = ENV.fetch('SIDEKIQ_WATCHDOG_ENABLED', 'true') == 'true'
end
