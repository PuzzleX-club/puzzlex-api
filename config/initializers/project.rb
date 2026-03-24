# frozen_string_literal: true

Rails.application.config.x.project = ActiveSupport::OrderedOptions.new
Rails.application.config.x.project.default_key = ENV.fetch('DEFAULT_PROJECT_KEY', 'default')
