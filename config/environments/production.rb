require "active_support/core_ext/integer/time"

Rails.application.configure do
  # Settings specified here will take precedence over those in config/application.rb.

  # Code is not reloaded between requests.
  config.enable_reloading = false

  # Eager load code on boot. This eager loads most of Rails and
  # your application in memory, allowing both threaded web servers
  # and those relying on copy on write to perform better.
  # Rake tasks automatically ignore this option for performance.
  config.eager_load = true

  # Full error reports are disabled and caching is turned on.
  config.consider_all_requests_local = false
  config.action_controller.perform_caching = true

  # Ensures that a master key has been made available in ENV["RAILS_MASTER_KEY"], config/master.key, or an environment
  # key such as config/credentials/production.key. This key is used to decrypt credentials (and other encrypted files).
  # config.require_master_key = true

  # Disable serving static files from `public/`, relying on NGINX/Apache to do so instead.没使用nginx，先放开静态文件
  config.public_file_server.enabled = true

  # API-only模式不需要assets相关配置
  # config.assets.css_compressor = :sass
  # config.assets.compile = false

  # Enable serving of images, stylesheets, and JavaScripts from an asset server.
  # config.asset_host = "http://assets.example.com"

  # Specifies the header that your server uses for sending files.
  # config.action_dispatch.x_sendfile_header = "X-Sendfile" # for Apache
  # config.action_dispatch.x_sendfile_header = "X-Accel-Redirect" # for NGINX

  # Mount Action Cable outside main process or domain. 添加EX前端至允许源头
  # config.action_cable.mount_path = nil
  config.action_cable.mount_path = "/cable"
  config.action_cable.url = ENV.fetch("ACTION_CABLE_URL", "wss://localhost/cable")
  # Action Cable WebSocket 来源限制
  # 本地调试：设置环境变量 ALLOW_ALL_HOSTS=true 来允许所有来源
  if ENV['ALLOW_ALL_HOSTS'] == 'true'
    config.action_cable.allowed_request_origins = nil  # 允许所有来源（仅用于本地调试）
  else
    allowed = ENV.fetch("ACTION_CABLE_ALLOWED_ORIGINS", "").split(",").map(&:strip)
    allowed += [/http:\/\/localhost:\d+/, /http:\/\/127\.0\.0\.1:\d+/]
    config.action_cable.allowed_request_origins = allowed
  end

  # Assume all access to the app is happening through a SSL-terminating reverse proxy.
  # Can be used together with config.force_ssl for Strict-Transport-Security and secure cookies.
  # config.assume_ssl = true

  # Force all access to the app over SSL, use Strict-Transport-Security, and use secure cookies.暂时改为false
  # TODO：temp disable ssl
  config.force_ssl = false

  # Log to STDOUT by default
  config.logger = ActiveSupport::Logger.new(STDOUT)
    .tap  { |logger| logger.formatter = ::Logger::Formatter.new }
    .then { |logger| ActiveSupport::TaggedLogging.new(logger) }

  # Prepend all log lines with the following tags.
  config.log_tags = [
    :request_id,
    :remote_ip,
    :uuid,
    :subdomain
  ]

  # "info" includes generic and useful information about system operation, but avoids logging too much
  # information to avoid inadvertent exposure of personally identifiable information (PII). If you
  # want to log everything, set the level to "debug".
  config.log_level = ENV.fetch("RAILS_LOG_LEVEL", "info")

  # Use a different cache store in production.
  # config.cache_store = :mem_cache_store

  # Use a real queuing backend for Active Job (and separate queues per environment).
  # config.active_job.queue_adapter = :resque
  # config.active_job.queue_name_prefix = "puzzlex_production"

  # Enable locale fallbacks for I18n (makes lookups for any locale fall back to
  # the I18n.default_locale when a translation cannot be found).
  config.i18n.fallbacks = true

  # Don't log any deprecations.
  config.active_support.report_deprecations = false

  # Do not dump schema after migrations.
  config.active_record.dump_schema_after_migration = false
  # 我们在多个业务表中使用 numeric(78,0) 承载链上 uint256（wei）值，
  # 关闭 64 位整数保护，避免 upsert_all 在大整数 numeric 上误报越界。
  ActiveRecord.raise_int_wider_than_64bit = false

  # Enable DNS rebinding protection and other `Host` header attacks.
  # TODO： 调试模式：设置环境变量 ALLOW_ALL_HOSTS=true 来允许所有域名访问
  if ENV['ALLOW_ALL_HOSTS'] == 'true' || ENV['ALLOW_ALL_HOSTS'] == 'TRUE'
    # 完全禁用 host authorization 检查
    config.hosts.clear
    # 完全禁用 Host Authorization 中间件
    config.host_authorization = { exclude: ->(request) { true } }
  else
    extra_hosts = ENV.fetch("ALLOWED_HOSTS", "").split(",").map(&:strip)
    config.hosts = [
      IPAddr.new("0.0.0.0/0"),
      IPAddr.new("::/0"),
      ENV["RAILS_DEVELOPMENT_HOSTS"],
      "localhost",
      "127.0.0.1",
      /.*\.local/
    ].compact + extra_hosts
    config.host_authorization = { exclude: ->(request) { true } }
    # config.host_authorization = {
    #   exclude: ->(request) {
    #     # 排除健康检查路径
    #     request.path == "/health" || request.path == "/up"
    #   }
    # }
  end
  # Trust Cloudflare edge nodes so request.remote_ip resolves to real visitors
  config.action_dispatch.trusted_proxies = (
    %w[
      103.21.244.0/22
      103.22.200.0/22
      103.31.4.0/22
      104.16.0.0/13
      104.24.0.0/14
      108.162.192.0/18
      131.0.72.0/22
      141.101.64.0/18
      162.158.0.0/15
      172.64.0.0/13
      173.245.48.0/20
      188.114.96.0/20
      190.93.240.0/20
      197.234.240.0/22
      198.41.128.0/17
    ] + %w[
      2400:cb00::/32
      2606:4700::/32
      2803:f800::/32
      2405:b500::/32
      2405:8100::/32
      2a06:98c0::/29
      2c0f:f248::/32
    ]
  ).map { |cidr| IPAddr.new(cidr) }
  # Skip DNS rebinding protection for the default health check endpoint.
  # config.host_authorization = { exclude: ->(request) { request.path == "/up" } }

  # Redis URL 统一入口（default/cache 用 /0，sidekiq 用 /1）
  config.x.redis.default_url = ENV.fetch('REDIS_URL', 'redis://localhost:6379/0')
  config.x.redis.sidekiq_url = ENV.fetch('SIDEKIQ_REDIS_URL', config.x.redis.default_url.sub(/\/\d+$/, '/1'))
  config.x.redis.cache_url   = config.x.redis.default_url
  config.x.redis.cable_url   = config.x.redis.sidekiq_url

  config.x.log_collector = ActiveSupport::OrderedOptions.new
  config.x.log_collector.retention_days = ENV.fetch('LOG_COLLECTOR_RETENTION_DAYS', '30').to_i
  config.x.log_collector.max_consecutive_failures = ENV.fetch('LOG_COLLECTOR_MAX_CONSECUTIVE_FAILURES', '10').to_i
  config.x.log_collector.error_backoff_max = ENV.fetch('LOG_COLLECTOR_ERROR_BACKOFF_MAX', '30').to_f
  config.x.log_collector.catchup_threshold = ENV.fetch('LOG_COLLECTOR_CATCHUP_THRESHOLD', '1000').to_i
  config.x.log_collector.rps = ENV.fetch('LOG_COLLECTOR_RPS', '5').to_f
  config.x.log_collector.catchup_rps = ENV.fetch('LOG_COLLECTOR_CATCHUP_RPS', '10').to_f

  # config.cache_store = :redis_cache_store, {
  #   url: config.x.redis.cache_url,
  #   namespace: 'puzzlex_cache',
  #   expires_in: 6.hour
  # }

  config.service_hosts = {
    'market_server' => ENV.fetch('GATEWAY_MARKET_SERVER_URL', 'http://localhost:3000/api/market'),
    'order_service' => ENV.fetch('GATEWAY_ORDER_SERVICE_URL', 'http://localhost:3000/api/order'),
    'user_service' => ENV.fetch('GATEWAY_USER_SERVICE_URL', 'http://localhost:3000/api/user')
  }

  # 区块链配置 - 生产环境（所有值必须通过 ENV 提供）
  config.x.blockchain.rpc_url = ENV.fetch('BLOCKCHAIN_RPC_URL')
  config.x.blockchain.chain_id = ENV.fetch('CHAIN_ID').to_i
  config.x.blockchain.seaport_contract_address = ENV.fetch('SEAPORT_CONTRACT_ADDRESS')
  config.x.blockchain.nft_contract_address = ENV.fetch('NFT_CONTRACT_ADDRESS')
  config.x.blockchain.erc20_contract_address = ENV.fetch('ERC20_CONTRACT_ADDRESS')
  config.x.blockchain.zone_contract_address = ENV.fetch('ZONE_CONTRACT_ADDRESS')
  config.x.blockchain.allowed_zone_manager_address = ENV.fetch('ALLOWED_ZONE_MANAGER_ADDRESS')
  config.x.blockchain.conduit_controller_address = ENV.fetch('CONDUIT_CONTROLLER_ADDRESS')
  config.x.blockchain.event_listener_genesis_block = ENV.fetch('EVENT_LISTENER_GENESIS_BLOCK').to_i

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
  config.x.match_logging.max_queue_operations = ENV.fetch('MATCH_LOGGING_MAX_QUEUE_OPERATIONS', '80').to_i
  config.x.match_logging.cancelled_noop_sampling_rate = ENV.fetch('MATCH_LOGGING_CANCELLED_NOOP_SAMPLING_RATE', '0.02').to_f

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
  config.x.match_scheduler.worker_timeout_sec   = ENV.fetch('MATCH_SCHEDULER_WORKER_TIMEOUT_SEC', '10').to_i
  config.x.match_scheduler.lock_ttl_sec         = ENV.fetch('MATCH_SCHEDULER_LOCK_TTL_SEC', '15').to_i
  config.x.match_scheduler.loop_budget_sec      = ENV.fetch('MATCH_SCHEDULER_LOOP_BUDGET_SEC', '5').to_i
  config.x.match_scheduler.followup_delay_sec   = ENV.fetch('MATCH_SCHEDULER_FOLLOWUP_DELAY_SEC', '1').to_f
  config.x.match_scheduler.waiting_delay_sec    = ENV.fetch('MATCH_SCHEDULER_WAITING_DELAY_SEC', '10').to_i
  config.x.match_scheduler.dedup_ttl_sec        = ENV.fetch('MATCH_SCHEDULER_DEDUP_TTL_SEC', '2').to_i

  # CatalogProvider 配置已迁移至 config/initializers/catalog_provider.rb

  # Sidekiq选举系统配置
  config.x.sidekiq_election = ActiveSupport::OrderedOptions.new
  config.x.sidekiq_election.enabled = ENV.fetch('SIDEKIQ_ELECTION_ENABLED', 'false') == 'true'  # 默认禁用动态选举，使用静态 Leader 模式
  config.x.sidekiq_election.heartbeat_interval = ENV.fetch('SIDEKIQ_ELECTION_HEARTBEAT_INTERVAL', '10').to_i
  config.x.sidekiq_election.heartbeat_jitter = ENV.fetch('SIDEKIQ_ELECTION_HEARTBEAT_JITTER', '2').to_i
  config.x.sidekiq_election.ttl_seconds = ENV.fetch('SIDEKIQ_ELECTION_TTL_SECONDS', '60').to_i  # 从35提升到60
  config.x.sidekiq_election.max_consecutive_failures = ENV.fetch('SIDEKIQ_ELECTION_MAX_FAILURES', '5').to_i  # 从3提升到5
  config.x.sidekiq_election.redis_url = config.x.redis.default_url
  config.x.sidekiq_election.log_level = ENV.fetch('SIDEKIQ_ELECTION_LOG_LEVEL', 'info')
  config.x.sidekiq_election.monitoring_enabled = ENV.fetch('SIDEKIQ_ELECTION_MONITORING_ENABLED', 'true') == 'true'
  config.x.sidekiq_election.static_leader_index = ENV.fetch('SIDEKIQ_STATIC_LEADER_INDEX', '0').to_i  # 静态 Leader 模式：INDEX=0 为 Leader

  # Watchdog 配置（云原生 - 环境变量化）
  config.x.sidekiq_election.watchdog_check_interval = ENV.fetch('SIDEKIQ_WATCHDOG_CHECK_INTERVAL', '20').to_i
  config.x.sidekiq_election.watchdog_check_jitter = ENV.fetch('SIDEKIQ_WATCHDOG_CHECK_JITTER', '3').to_i
  config.x.sidekiq_election.watchdog_acquire_jitter = ENV.fetch('SIDEKIQ_WATCHDOG_ACQUIRE_JITTER', '5').to_i
  config.x.sidekiq_election.watchdog_stale_threshold = ENV.fetch('SIDEKIQ_WATCHDOG_STALE_THRESHOLD', '30').to_i
  config.x.sidekiq_election.watchdog_enabled = ENV.fetch('SIDEKIQ_WATCHDOG_ENABLED', 'true') == 'true'
end
