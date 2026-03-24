# 集成测试安全配置
# 通过显式环境开关 + 共享密钥控制访问，不再仅依赖 Rails.env.test?

Rails.application.configure do
  if ENV['INTEGRATION_TEST_API_ENABLED'] == 'true'
    begin
      redis_url = Rails.application.config.x.redis.default_url
      redis_conn = Redis.new(url: redis_url)
      redis_conn.ping
      Rails.logger.info "[SECURITY] ✅ Integration Test API enabled in #{Rails.env}, Redis连接正常 (#{redis_url})"
      redis_conn.close
    rescue => e
      Rails.logger.error "[SECURITY] ❌ Integration Test API enabled but Redis连接失败: #{e.message} (#{redis_url})"
    end
  else
    Rails.logger.info "[SECURITY] Integration Test API disabled in #{Rails.env} (set INTEGRATION_TEST_API_ENABLED=true to enable)"
  end
end

# 运行时安全检查模块
module IntegrationTestSecurity
  SECRET_HEADER = 'X-Integration-Test-Secret'.freeze

  def self.enabled?
    ENV['INTEGRATION_TEST_API_ENABLED'] == 'true'
  end

  def self.disabled?
    ENV['INTEGRATION_TESTS_DISABLED'] == 'true'
  end

  def self.configured_secret
    ENV['INTEGRATION_TEST_API_SECRET'].to_s
  end

  def self.secret_configured?
    configured_secret.present?
  end

  def self.integration_secret_valid?(provided_secret)
    return false unless secret_configured?
    return false if provided_secret.blank?

    ActiveSupport::SecurityUtils.secure_compare(provided_secret.to_s, configured_secret)
  rescue ArgumentError
    false
  end

  # 检查当前环境是否安全执行集成测试
  def self.safe_for_integration_tests?
    return false unless enabled?
    return false if disabled?
    return false unless secret_configured?

    true
  end
  
  # 生成安全报告
  def self.security_report
    {
      environment: Rails.env,
      safe_for_tests: safe_for_integration_tests?,
      database: Rails.application.config.database_configuration[Rails.env]["database"],
      redis_working: redis_available?,
      security_checks: {
        flag_enabled: enabled?,
        tests_enabled: !disabled?,
        secret_configured: secret_configured?
      }
    }
  end
  
  private
  
  def self.redis_available?
    redis_url = Rails.application.config.x.redis.default_url
    redis_conn = Redis.new(url: redis_url)
    result = redis_conn.ping == "PONG"
    redis_conn.close
    result
  rescue
    false
  end
end
