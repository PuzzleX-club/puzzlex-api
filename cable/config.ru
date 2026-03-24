# frozen_string_literal: true

require_relative '../config/environment'

# Cable 只依赖 WebSocket，不需要 CSRF 校验
Rails.application.config.action_cable.disable_request_forgery_protection = true

run ActionCable.server
