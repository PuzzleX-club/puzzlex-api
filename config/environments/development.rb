require "active_support/core_ext/integer/time"

Rails.application.configure do
  # Settings specified here will take precedence over those in config/application.rb.

  # In the development environment your application's code is reloaded any time
  # it changes. This slows down response time but is perfect for development
  # since you don't have to restart the web server when you make code changes.
  config.enable_reloading = true

  # API-only模式不需要sass配置
  # if defined?(SassC)
  #   config.sass.inline_source_maps = true
  # end

  # Do not eager load code on boot.
  config.eager_load = false

  # Show full error reports.
  config.consider_all_requests_local = true

  # Enable server timing
  config.server_timing = true

  config.log_level = :debug

  # Enable/disable caching. By default caching is disabled.
  # Run rails dev:cache to toggle caching.
  # 测试redis缓存，暂时注释
  # if Rails.root.join("tmp/caching-dev.txt").exist?
  #   config.action_controller.perform_caching = true
  #   config.action_controller.enable_fragment_cache_logging = true
  #
  #   config.cache_store = :memory_store
  #   config.public_file_server.headers = {
  #     "Cache-Control" => "public, max-age=#{2.days.to_i}"
  #   }
  # else
  #   config.action_controller.perform_caching = false
  #
  #   config.cache_store = :null_store
  # end

  # Print deprecation notices to the Rails logger.
  config.active_support.deprecation = :log

  # Raise exceptions for disallowed deprecations.
  config.active_support.disallowed_deprecation = :raise

  # Tell Active Support which deprecation messages to disallow.
  config.active_support.disallowed_deprecation_warnings = []

  # Raise an error on page load if there are pending migrations.
  config.active_record.migration_error = :page_load
  # numeric(78,0)（wei）会超过 int64，关闭该保护避免大整数 numeric 被误判越界。
  ActiveRecord.raise_int_wider_than_64bit = false

  # Highlight code that triggered database queries in logs.
  config.active_record.verbose_query_logs = true

  # Highlight code that enqueued background job in logs.
  config.active_job.verbose_enqueue_logs = true

  # API-only模式不需要assets配置
  # config.assets.quiet = true

  # Raises error for missing translations.
  # config.i18n.raise_on_missing_translations = true

  # Annotate rendered view with file names.
  # config.action_view.annotate_rendered_view_with_filenames = true

  # Uncomment if you wish to allow Action Cable access from any origin.
  config.action_cable.disable_request_forgery_protection = true

  # Raise error when a before_action's only/except options reference missing actions
  config.action_controller.raise_on_missing_callback_actions = true

  # Redis URL 统一入口
  config.x.redis.default_url = ENV.fetch('REDIS_URL', 'redis://localhost:6380/0')
  config.x.redis.sidekiq_url = ENV.fetch('SIDEKIQ_REDIS_URL', config.x.redis.default_url.sub(/\/\d+$/, '/1'))
  config.x.redis.cache_url   = config.x.redis.default_url
  config.x.redis.cable_url   = config.x.redis.sidekiq_url

  config.cache_store = :redis_cache_store, {
    url: config.x.redis.cache_url,
    namespace: 'puzzlex_cache',
    expires_in: 6.hour
  }

  config.action_cable.mount_path = "/cable"
  config.action_cable.url = "ws://localhost:3000/cable"
  config.action_cable.allowed_request_origins = ['http://localhost:5173', /http:\/\/127\.0\.0\.1:\d+/]

  config.service_hosts = {
    'market_server' => 'http://localhost:3000/api/market',
    'order_service' => 'http://localhost:3000/api/order',
    'user_service' => 'http://localhost:3000/api/user'
  }

  config.x.log_collector = ActiveSupport::OrderedOptions.new
  config.x.log_collector.retention_days = 30
  config.x.log_collector.max_consecutive_failures = ENV.fetch('LOG_COLLECTOR_MAX_CONSECUTIVE_FAILURES', '10').to_i
  config.x.log_collector.error_backoff_max = ENV.fetch('LOG_COLLECTOR_ERROR_BACKOFF_MAX', '30').to_f
  config.x.log_collector.catchup_threshold = ENV.fetch('LOG_COLLECTOR_CATCHUP_THRESHOLD', '1000').to_i
  config.x.log_collector.rps = ENV.fetch('LOG_COLLECTOR_RPS', '5').to_f
  config.x.log_collector.catchup_rps = ENV.fetch('LOG_COLLECTOR_CATCHUP_RPS', '10').to_f

  # 区块链配置（必须在 .env 中提供）
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
  config.x.match_logging.persist_started = ENV.fetch('MATCH_LOGGING_PERSIST_STARTED', 'true') == 'true'
  config.x.match_logging.store_order_hashes = ENV.fetch('MATCH_LOGGING_STORE_ORDER_HASHES', 'true') == 'true'
  config.x.match_logging.max_order_hashes_per_operation = ENV.fetch('MATCH_LOGGING_MAX_ORDER_HASHES', '12').to_i
  config.x.match_logging.max_queue_operations = ENV.fetch('MATCH_LOGGING_MAX_QUEUE_OPERATIONS', '150').to_i
  config.x.match_logging.cancelled_noop_sampling_rate = ENV.fetch('MATCH_LOGGING_CANCELLED_NOOP_SAMPLING_RATE', '1.0').to_f

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

  # Sidekiq选举系统配置（开发环境）
  config.x.sidekiq_election = ActiveSupport::OrderedOptions.new
  config.x.sidekiq_election.enabled = ENV.fetch('SIDEKIQ_ELECTION_ENABLED', 'true') == 'true'
  config.x.sidekiq_election.heartbeat_interval = ENV.fetch('SIDEKIQ_ELECTION_HEARTBEAT_INTERVAL', '10').to_i
  config.x.sidekiq_election.heartbeat_jitter = ENV.fetch('SIDEKIQ_ELECTION_HEARTBEAT_JITTER', '2').to_i
  config.x.sidekiq_election.ttl_seconds = ENV.fetch('SIDEKIQ_ELECTION_TTL_SECONDS', '35').to_i
  config.x.sidekiq_election.max_consecutive_failures = ENV.fetch('SIDEKIQ_ELECTION_MAX_FAILURES', '3').to_i
  config.x.sidekiq_election.redis_url = config.x.redis.default_url
  config.x.sidekiq_election.log_level = ENV.fetch('SIDEKIQ_ELECTION_LOG_LEVEL', 'debug')
  config.x.sidekiq_election.monitoring_enabled = ENV.fetch('SIDEKIQ_ELECTION_MONITORING_ENABLED', 'true') == 'true'
  config.x.sidekiq_election.static_leader_index = ENV.fetch('SIDEKIQ_STATIC_LEADER_INDEX', '0').to_i  # 静态 Leader 模式：INDEX=0 为 Leader
  config.x.sidekiq_election.watchdog_enabled = ENV.fetch('SIDEKIQ_WATCHDOG_ENABLED', 'true') == 'true'

end
