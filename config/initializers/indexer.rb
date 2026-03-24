# frozen_string_literal: true

# Indexer configuration
# Responsibility: on-chain item transfer event indexing (ERC1155)
#
# Instance-level metadata config lives in instance_metadata.rb.
# This file only handles chain indexer concerns.

Rails.application.config.x.indexer = ActiveSupport::OrderedOptions.new

# Safe defaults — local Anvil for test, no-op for other envs unless env vars are set.
defaults = if Rails.env.test?
  { contract_address: '0x70E7F91B5dFbBbd860206a596e947BE31Cec742c', start_block: 0, rpc_endpoint: 'http://127.0.0.1:8546' }
else
  { contract_address: nil, start_block: 0, rpc_endpoint: nil }
end

# 合约配置（环境变量可覆盖默认值）
Rails.application.config.x.indexer.contract_address = ENV.fetch('INDEXER_CONTRACT_ADDRESS', defaults[:contract_address])
Rails.application.config.x.indexer.start_block = ENV.fetch('INDEXER_START_BLOCK', defaults[:start_block].to_s).to_i
Rails.application.config.x.indexer.rpc_endpoint = ENV.fetch('INDEXER_RPC_ENDPOINT', defaults[:rpc_endpoint])

# 索引器配置（可选，有默认值）
Rails.application.config.x.indexer.block_batch_size = ENV.fetch('INDEXER_BLOCK_BATCH_SIZE', '90').to_i
Rails.application.config.x.indexer.polling_interval = ENV.fetch('INDEXER_POLLING_INTERVAL', '5').to_i

# Log loaded config
if defined?(Rails.logger) && Rails.logger
  cfg = Rails.application.config.x.indexer
  im = Rails.application.config.x.instance_metadata
  Rails.logger.info "[Indexer] Config loaded (#{Rails.env})"
  Rails.logger.info "[Indexer] RPC: #{cfg.rpc_endpoint || '(not set)'}"
  Rails.logger.info "[Indexer] Contract: #{cfg.contract_address || '(not set)'}"
  Rails.logger.info "[Indexer] Start block: #{cfg.start_block}"

  if im.enabled
    Rails.logger.info "[InstanceMetadata] Enabled, API: #{im.api_base_url}"
  else
    Rails.logger.info "[InstanceMetadata] Disabled"
  end
end
