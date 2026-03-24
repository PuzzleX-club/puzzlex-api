# 日志轮转配置
# 防止日志文件过大，特别是测试环境

if Rails.env.test?
  # 测试环境日志轮转配置
  # - 最多保留5个历史文件
  # - 每个文件最大100MB
  # - 自动轮转和压缩
  
  log_file = Rails.root.join('log', "#{Rails.env}.log")
  
  # 创建带轮转功能的logger
  logger = ActiveSupport::Logger.new(
    log_file,
    5,                    # 保留5个历史文件
    100 * 1024 * 1024    # 每个文件最大100MB
  )
  
  # 设置日志格式
  logger.formatter = proc do |severity, datetime, progname, msg|
    "[#{datetime.strftime('%Y-%m-%d %H:%M:%S')}] [#{severity}] #{msg}\n"
  end
  
  # 应用到Rails
  Rails.application.config.logger = ActiveSupport::TaggedLogging.new(logger)
  
  # 同时配置ActiveRecord日志
  ActiveRecord::Base.logger = Rails.application.config.logger
  
  Rails.logger.info "✅ 日志轮转已配置: 最大100MB，保留5个文件"
end

# 生产环境也可以配置（可选）
if Rails.env.production?
  log_file = Rails.root.join('log', "#{Rails.env}.log")
  
  logger = ActiveSupport::Logger.new(
    log_file,
    10,                   # 保留10个历史文件
    500 * 1024 * 1024    # 每个文件最大500MB
  )
  
  logger.formatter = proc do |severity, datetime, progname, msg|
    "[#{datetime.strftime('%Y-%m-%d %H:%M:%S')}] [#{severity}] [#{progname}] #{msg}\n"
  end
  
  Rails.application.config.logger = ActiveSupport::TaggedLogging.new(logger)
  ActiveRecord::Base.logger = Rails.application.config.logger
end