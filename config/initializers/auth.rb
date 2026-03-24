# frozen_string_literal: true

Rails.application.config.x.auth = ActiveSupport::OrderedOptions.new

# JWT signing secret — used for all token encode/decode operations.
# Canonical source: AUTH_JWT_SECRET env var.
# Fallback: SECRET_KEY_BASE env var (Rails standard).
# OSS deployments must set at least one of these.
Rails.application.config.x.auth.jwt_secret =
  ENV['AUTH_JWT_SECRET'] || ENV['SECRET_KEY_BASE'] || Rails.application.secret_key_base

if Rails.application.config.x.auth.jwt_secret.blank?
  raise "JWT signing secret not configured. Set AUTH_JWT_SECRET or SECRET_KEY_BASE."
end

Rails.application.config.x.auth.allow_unregistered_login =
  ENV.fetch('ALLOW_UNREGISTERED_LOGIN', 'true') == 'true'

if Rails.application.config.x.auth.allow_unregistered_login
  Rails.logger.info '[AUTH] Unregistered login is enabled.'
end
