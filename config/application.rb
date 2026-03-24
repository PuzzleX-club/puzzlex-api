require_relative "boot"

require "active_model/railtie"
require "active_job/railtie"
require "active_record/railtie"
require "action_controller/railtie"
require "action_cable/engine"
require "rails/test_unit/railtie"

# Require the gems listed in Gemfile, including any gems
# you've limited to :test, :development, or :production.
Bundler.require(*Rails.groups)

# puts "Loading application.rb - Top"
# puts "Rails environment: #{Rails.env}"

module Puzzlex
  class Application < Rails::Application
    # Initialize configuration defaults for originally generated Rails version.
    config.load_defaults 7.1

    # Please, add to the `ignore` list any other `lib` subdirectories that do
    # not contain `.rb` files, or that should not be reloaded or eager loaded.
    # Common ones are `templates`, `generators`, or `middleware`, for example.
    config.autoload_lib(ignore: %w(assets tasks))

    # Configuration for the application, engines, and railties goes here.
    #
    # These settings can be overridden in specific environments using the files
    # in config/environments, which are processed later.
    #
    # config.time_zone = "Central Time (US & Canada)"
    # config.time_zone = 'Beijing'
    # config.eager_load_paths << Rails.root.join("extras")
    # API-only模式不需要action_view配置
    # config.action_view.form_with_generates_remote_forms = false
    # API-only模式不需要uglifier
    # config.require_dependency 'uglifier'
    config.api_only = true

    # 配置i18n（可通过 SUPPORTED_LOCALES 环境变量覆盖）
    config.i18n.default_locale = :"zh-CN"
    config.i18n.available_locales = ENV.fetch('SUPPORTED_LOCALES', 'zh-CN,en')
      .split(',')
      .map(&:to_sym)

    # 添加额外的加载路径
    config.autoload_paths += %W(#{config.root}/app/queries)
    # 用于加载constants
    config.autoload_paths << Rails.root.join('lib')

    # Sidekiq分层目录 - 只添加根目录，让Zeitwerk自动处理子目录
    config.autoload_paths << Rails.root.join('app/sidekiq')

    config.logger = ActiveSupport::Logger.new("log/#{Rails.env}.log")

    config.middleware.insert_before 0, Rack::Cors do
      allow do
        origins 'http://localhost:3000', 'http://127.0.0.1:5173', 'http://localhost:5173'  # 前端的域名
        resource '*',
                 headers: :any,
                 methods: [:get, :post, :patch, :put, :delete, :options, :head],
                 credentials: true  # 允许 credentials
      end
    end
    config.middleware.use Rack::Attack

    config.active_job.queue_adapter = :sidekiq

    # 静音 Rails 的 Deprecation Warnings
    config.active_support.deprecation = :silence

    # Redis 配置命名空间（各 environment 填充具体 URL）
    config.x.redis = ActiveSupport::OrderedOptions.new

    # Blockchain 配置命名空间（各 environment 填充合约地址等）
    config.x.blockchain = ActiveSupport::OrderedOptions.new

    # Merkle树生成相关配置
    config.x.merkle_tree = ActiveSupport::OrderedOptions.new
    config.x.merkle_tree.max_tokens_per_tree = 100_000  # 单个Merkle树最大token数量
    config.x.merkle_tree.batch_size_limit = 5_000       # 批处理最大限制
    config.x.merkle_tree.memory_warning_threshold = 500  # 内存使用警告阈值(MB)
    config.x.merkle_tree.timeout_seconds = 3600         # 生成超时时间(秒)

    # ============================================
    # Price Token 配置 (云原生 - 动态代币映射)
    # 扫描 PRICE_TOKEN_XX_SYMBOL 和 PRICE_TOKEN_XX_ADDRESS 环境变量
    # 全环境统一从环境变量读取，支持动态扩展代币数量
    # ============================================
    config.x.price_tokens = {}.tap do |tokens|
      ENV.each do |key, value|
        if key.match?(/^PRICE_TOKEN_(\d{2})_SYMBOL$/)
          code = key.match(/^PRICE_TOKEN_(\d{2})_SYMBOL$/)[1]
          tokens[code] ||= {}
          tokens[code][:symbol] = value
        elsif key.match?(/^PRICE_TOKEN_(\d{2})_ADDRESS$/)
          code = key.match(/^PRICE_TOKEN_(\d{2})_ADDRESS$/)[1]
          tokens[code] ||= {}
          tokens[code][:address] = value
        end
      end
    end.freeze

    # ============================================
    # Admin Feature Flag (云原生 - 管理后台开关)
    # 控制 Admin API 路由是否启用
    # 参考设计: docs/plans/precious-tinkering-wave.md
    # ============================================
    # 交易所后端: ENABLE_ADMIN_FEATURES=false → Admin 路由完全不注册
    # 管理后端: ENABLE_ADMIN_FEATURES=true → 仅管理员可访问
    config.admin_features_enabled = ENV.fetch('ENABLE_ADMIN_FEATURES', 'false') == 'true'

  end
end
