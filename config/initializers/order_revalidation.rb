# frozen_string_literal: true

Rails.application.config.x.order_revalidation = {
  max_attempts: ENV.fetch('ORDER_REVALIDATION_MAX_ATTEMPTS', '3').to_i,
  lock_seconds: ENV.fetch('ORDER_REVALIDATION_LOCK_SECONDS', '30').to_i
}
