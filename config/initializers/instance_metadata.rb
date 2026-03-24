# frozen_string_literal: true

# Instance Metadata Provider — canonical configuration
#
# Provides metadata for NFT token instances (name, description, image, attributes).
#
# Public release only supports canonical env names: INSTANCE_METADATA_*
# Safety: If enabled=true but API base URL is missing, auto-disables with a warning.

cfg = Rails.application.config
cfg.x.instance_metadata = ActiveSupport::OrderedOptions.new

cfg.x.instance_metadata.provider = ENV.fetch('INSTANCE_METADATA_PROVIDER', 'api').to_sym

# Enabled flag — test env defaults to false, others to true
raw_enabled = ENV.fetch('INSTANCE_METADATA_ENABLED', Rails.env.test? ? 'false' : 'true')

# API base URL — no private default; must be explicitly configured
api_base_url = ENV['INSTANCE_METADATA_API_BASE_URL']

# Safety gate: enabled=true but no URL → auto-disable
if raw_enabled == 'true' && api_base_url.blank?
  Rails.logger&.warn "[InstanceMetadata] enabled=true but INSTANCE_METADATA_API_BASE_URL not set — auto-disabling"
  cfg.x.instance_metadata.enabled = false
else
cfg.x.instance_metadata.enabled = (raw_enabled == 'true')
end

cfg.x.instance_metadata.api_base_url           = api_base_url
cfg.x.instance_metadata.batch_size              = ENV.fetch('INSTANCE_METADATA_BATCH_SIZE', '200').to_i
cfg.x.instance_metadata.batch_size_min          = ENV.fetch('INSTANCE_METADATA_BATCH_SIZE_MIN', '10').to_i
cfg.x.instance_metadata.batch_size_step         = ENV.fetch('INSTANCE_METADATA_BATCH_SIZE_STEP', '50').to_i
cfg.x.instance_metadata.rate_limit_cooldown     = ENV.fetch('INSTANCE_METADATA_RATE_LIMIT_COOLDOWN', '60').to_i
cfg.x.instance_metadata.recovery_threshold      = ENV.fetch('INSTANCE_METADATA_RECOVERY_THRESHOLD', '10').to_i
cfg.x.instance_metadata.simple_rate_limit       = ENV.fetch('INSTANCE_METADATA_SIMPLE_RATE_LIMIT', 'false') == 'true'
cfg.x.instance_metadata.empty_as_rate_limit     = ENV.fetch('INSTANCE_METADATA_EMPTY_AS_RATE_LIMIT', 'false') == 'true'
cfg.x.instance_metadata.retry_limit             = ENV.fetch('INSTANCE_METADATA_RETRY_LIMIT', '3').to_i
cfg.x.instance_metadata.fetch_interval          = ENV.fetch('INSTANCE_METADATA_FETCH_INTERVAL', '1').to_i
cfg.x.instance_metadata.scanner_queue_threshold = ENV.fetch('INSTANCE_METADATA_SCANNER_QUEUE_THRESHOLD', '500').to_i
