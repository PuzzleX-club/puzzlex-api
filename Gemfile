source "https://rubygems.org"

ruby ">=3.3.0"

# Bundle edge Rails instead: gem "rails", github: "rails/rails", branch: "main"
gem "rails", "~> 7.1.3"

# API-only模式不需要资源管道
# gem "sprockets-rails"

# Use sqlite3 as the database for Active Record
gem "sqlite3", "~> 1.4"

# Use the Puma web server [https://github.com/puma/puma]
gem "puma", ">= 5.0"

# API-only模式不需要前端资源管理
# gem "importmap-rails"
# gem "turbo-rails"
# gem "stimulus-rails"
# gem "jbuilder"

# Use Redis adapter to run Action Cable in production
gem "redis", ">= 4.0.1"

gem 'redis-rails'

# Use Kredis to get higher-level data types in Redis [https://github.com/rails/kredis]
# gem "kredis"

# Use Active Model has_secure_password [https://guides.rubyonrails.org/active_model_basics.html#securepassword]
# gem "bcrypt", "~> 3.1.7"

# Windows does not include zoneinfo files, so bundle the tzinfo-data gem
gem "tzinfo-data", platforms: %i[ windows jruby ]

# Reduces boot times through caching; required in config/boot.rb
gem "bootsnap", require: false

# Load environment variables from .env files
gem "dotenv-rails", groups: [:development, :test]

# API-only模式不需要前端框架
# gem 'bootstrap', '~> 5.3.2'
# gem 'sassc-rails'
# gem "jquery-rails"
# gem "select2-rails"

gem 'ransack'

gem 'ransack_memory'

# 安装分页功能
gem "will_paginate"

# API-only模式不需要表单助手和Devise（使用JWT认证）
# gem "simple_form"
# gem "devise"

gem "httparty"

gem "json"

gem "faraday"
gem "faraday-retry"  # Faraday 2.x 需要单独安装 retry 中间件

# API-only模式不需要JS压缩
# gem "uglifier"

gem 'acts_as_paranoid'

gem 'eth'

gem 'ethereum'

gem 'web3-eth'

# gem 'websocket-client-simple'

# API-only模式不需要论坛功能
# gem 'thredded'

# html-pipeline依赖，html-pipeline是threaded的依赖
# gem "rouge"
# threaded依赖
# gem "html-pipeline", "~> 2.14"

gem "pg"

gem 'rack-attack'

# gem 'active_analytics'

# 修改或移除 Gemfile 中的 stringio 依赖
gem 'stringio', '>= 3.1.0'

gem 'rack-cors', require: 'rack/cors'

gem 'abi_coder_rb'

# 🗑️ 已移除 (2025-07-14) - 改用seaport.js Node.js脚本生成签名，不再需要Ruby实现
# gem 'digest-keccak'

gem 'sidekiq'

gem 'sidekiq-scheduler'

gem 'sidekiq-unique-jobs'
# 为api即cable提供jwt
gem 'jwt'



# gem "capistrano", require:false
#
# gem "capistrano-rails", require:false

# Use Active Storage variants [https://guides.rubyonrails.org/active_storage_overview.html#transforming-images]
# gem "image_processing", "~> 1.2"

group :development, :test do
  # See https://guides.rubyonrails.org/debugging_rails_applications.html#debugging-with-the-debug-gem
  gem "debug", platforms: %i[ mri windows ]
  gem 'rspec-rails', '~> 5.0.0'
  gem 'factory_bot_rails'
end

group :development do
  # API-only模式不需要web-console
  # gem "web-console"

  # Add speed badges [https://github.com/MiniProfiler/rack-mini-profiler]
  # gem "rack-mini-profiler"

  # Speed up commands on slow machines / big apps [https://github.com/rails/spring]
  # gem "spring"
  gem "pry-rails"

end

group :test do
  # 代码覆盖率
  gem 'simplecov', require: false
  gem 'simplecov-json', require: false

  # JUnit 格式测试报告 (CI 使用)
  gem 'rspec_junit_formatter', require: false

  # 测试数据生成
  gem 'faker', require: false

  # 模型验证测试 matchers
  gem 'shoulda-matchers', '~> 5.0'
end
# gem "graphiql-rails", group: :development

# API-only模式不需要JS打包
# gem "jsbundling-rails", "~> 1.3"
