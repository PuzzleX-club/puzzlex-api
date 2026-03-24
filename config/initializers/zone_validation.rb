# frozen_string_literal: true

Rails.application.config.x.zone_validation = ActiveSupport::OrderedOptions.new
Rails.application.config.x.zone_validation.platform_fee_percentage =
  ENV.fetch('ZONE_PLATFORM_FEE_PERCENTAGE', '200').to_i
Rails.application.config.x.zone_validation.royalty_fee_percentage =
  ENV.fetch('ZONE_ROYALTY_FEE_PERCENTAGE', '250').to_i
Rails.application.config.x.zone_validation.platform_fee_recipient =
  ENV.fetch('ZONE_PLATFORM_FEE_RECIPIENT', '0x0000000000000000000000000000000000000000')
Rails.application.config.x.zone_validation.royalty_fee_recipient =
  ENV.fetch('ZONE_ROYALTY_FEE_RECIPIENT', '0x0000000000000000000000000000000000000000')
Rails.application.config.x.zone_validation.specified_erc20_tokens =
  ENV.fetch('ZONE_SPECIFIED_ERC20_TOKENS', '').split(',').map(&:strip).reject(&:blank?)
Rails.application.config.x.zone_validation.specified_addresses =
  ENV.fetch('ZONE_SPECIFIED_ADDRESSES', '').split(',').map(&:strip).reject(&:blank?)
