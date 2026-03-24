# frozen_string_literal: true

# Redis connection — consumes config.x.redis.default_url set in environments/*.rb
require 'redis'

class << Redis
  attr_accessor :current
end

redis_url = Rails.application.config.x.redis.default_url

if redis_url.present?
  Redis.current = Redis.new(url: redis_url)
  Rails.logger.info "[Redis] 连接到: #{redis_url.gsub(/\/\/.*@/, '//*:*@')}" if defined?(Rails.logger) && Rails.logger
else
  Rails.logger.warn "[Redis] config.x.redis.default_url 未设置，跳过 Redis 初始化" if defined?(Rails.logger) && Rails.logger
end
