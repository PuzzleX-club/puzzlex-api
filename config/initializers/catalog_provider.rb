# frozen_string_literal: true

# Catalog Provider — canonical configuration
#
# Provides static catalog data (items, recipes, translations) for the platform.
#
# Public release only supports canonical env names: CATALOG_REPO_SYNC_*
# Safety: If enabled=true but repo is missing, auto-disables with a warning.

cfg = Rails.application.config
cfg.x.catalog = ActiveSupport::OrderedOptions.new

cfg.x.catalog.provider = ENV.fetch('CATALOG_PROVIDER', 'repo_sync').to_sym

# --- repo_sync provider config ---

raw_enabled = ENV.fetch('CATALOG_REPO_SYNC_ENABLED', Rails.env.development? ? 'true' : 'false')

# Repo URL — no private default; must be explicitly configured
repo = ENV['CATALOG_REPO_SYNC_REPO']

# Safety gate: enabled=true but no repo → auto-disable
if raw_enabled == 'true' && repo.blank?
  Rails.logger&.warn "[CatalogProvider] enabled=true but CATALOG_REPO_SYNC_REPO not set — auto-disabling"
  effective_enabled = false
else
  effective_enabled = (raw_enabled == 'true')
end

# Environment-aware non-private defaults
is_test = Rails.env.test?

repo_sync_config = {
  enabled:              effective_enabled,
  repo:                 repo,
  branch:               ENV.fetch('CATALOG_REPO_SYNC_BRANCH', 'main'),
  supported_languages:  ENV.fetch('CATALOG_REPO_SYNC_SUPPORTED_LANGUAGES', 'zh-CN,en').split(','),
  data_dir:             ENV.fetch('CATALOG_REPO_SYNC_DATA_DIR', 'data/shared'),
  item_filename:        ENV.fetch('CATALOG_REPO_SYNC_ITEM_FILENAME', 'Item.csv'),
  recipes_filename:     ENV.fetch('CATALOG_REPO_SYNC_RECIPES_FILENAME', 'Recipes.csv'),
  timeout:              ENV.fetch('CATALOG_REPO_SYNC_TIMEOUT', is_test ? '30' : '60').to_i,
  lock_ttl:             ENV.fetch('CATALOG_REPO_SYNC_LOCK_TTL', is_test ? '60' : '300').to_i,
  debug:                ENV.fetch('CATALOG_REPO_SYNC_DEBUG', 'false') == 'true',
  github_token:         ENV['CATALOG_REPO_SYNC_GITHUB_TOKEN'],
  enable_notifications: ENV.fetch('CATALOG_REPO_SYNC_ENABLE_NOTIFICATIONS', 'false') == 'true'
}

cfg.x.catalog.providers = ActiveSupport::OrderedOptions.new
cfg.x.catalog.providers.repo_sync = repo_sync_config
