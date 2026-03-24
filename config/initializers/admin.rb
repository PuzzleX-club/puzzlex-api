# frozen_string_literal: true

Rails.application.config.x.admin = ActiveSupport::OrderedOptions.new
Rails.application.config.x.admin.skip_auth =
  ENV.fetch("ADMIN_SKIP_AUTH", "false") == "true"
