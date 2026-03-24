# frozen_string_literal: true

# Blockchain initializer — static assets and protocol constants only.
#
# Environment-specific config (rpc_url, contract addresses, etc.) is set
# directly in config/environments/*.rb via config.x.blockchain.*.
# This initializer only adds values that are the same across all environments.

cfg = Rails.application.config.x.blockchain

# Static assets
cfg.seaport_abi = JSON.parse(File.read(Rails.root.join('lib', 'constants', 'seaport_abi.json')))

# Protocol constants
cfg.seaport_max_uint256 = "115792089237316195423570985008687907853269984665640564039457584007913129639935"
cfg.conduit_key_to_conduit = {
  "0xeb8a03c8a86a78e5a48adf78cd9a701311bbbeade20265b574f6ebb5e9cd3189" => "0x1122710CEe5CFC923095dc7B9b5eaA1Fb2092A6e"
}.freeze

# Price token configuration (from config.x.price_tokens set in application.rb)
cfg.price_token_type_map = begin
  env_config = Rails.application.config.x.price_tokens

  if env_config.blank? || env_config.empty?
    raise "PRICE_TOKEN 配置缺失！请配置 PRICE_TOKEN_XX_SYMBOL 和 PRICE_TOKEN_XX_ADDRESS 环境变量"
  end

  env_config.each do |code, token|
    raise "PRICE_TOKEN_#{code}_SYMBOL 未配置" if token[:symbol].blank?
    raise "PRICE_TOKEN_#{code}_ADDRESS 未配置" if token[:address].blank?
  end

  env_config.transform_values { |v| v.symbolize_keys }.freeze
end
