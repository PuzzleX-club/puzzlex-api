# frozen_string_literal: true

# Catalog data sync job.
# Runs via sidekiq-scheduler; uses distributed lock to prevent concurrent runs.
#
# Canonical name: CatalogSyncJob
#
class CatalogSyncJob
  include Sidekiq::Job

  sidekiq_options queue: :default, retry: 3, unique: :until_executed

  LOCK_KEY = 'catalog_sync_job:lock'.freeze
  LOG_TAG  = 'CatalogSyncJob'

  def perform
    config = catalog_repo_sync_config

    provider = Metadata::Catalog::ProviderRegistry.current
    unless provider.enabled?
      Rails.logger.debug "[#{LOG_TAG}] catalog provider disabled, skipping"
      return
    end

    Rails.logger.info "[#{LOG_TAG}] ===== sync started ====="
    start_time = Time.current

    lock_acquired = acquire_distributed_lock(config[:lock_ttl])

    unless lock_acquired
      Rails.logger.info "[#{LOG_TAG}] another instance running, skipping"
      return
    end

    begin
      results = provider.sync_all

      duration = Time.current - start_time
      total_synced = 0

      results.each do |type, stats|
        next if stats[:error]

        created = stats[:created] || 0
        updated = stats[:updated] || 0
        total_synced += created + updated

        Rails.logger.info "[#{LOG_TAG}] #{type}: created=#{created} updated=#{updated}"
      end

      if total_synced > 0
        Rails.logger.info "[#{LOG_TAG}] sync complete: #{total_synced} records updated in #{duration.round(2)}s"
        send_notification("Catalog sync complete", "#{total_synced} records updated") if should_send_notification?
      else
        Rails.logger.info "[#{LOG_TAG}] sync complete: no changes in #{duration.round(2)}s"
      end

    rescue StandardError => e
      Rails.logger.error "[#{LOG_TAG}] sync failed: #{e.message}"
      Rails.logger.error e.backtrace.join("\n")

      send_notification("Catalog sync failed", e.message, error: true) if should_send_notification?

      raise
    ensure
      release_distributed_lock
    end

    Rails.logger.info "[#{LOG_TAG}] ===== sync finished ====="
  end

  private

  def acquire_distributed_lock(ttl = 300)
    result = nil
    Sidekiq.redis do |conn|
      result = conn.set(LOCK_KEY, SecureRandom.uuid, nx: true, ex: ttl)
    end

    if result
      Rails.logger.info "[#{LOG_TAG}] distributed lock acquired, TTL=#{ttl}s"
      true
    else
      Rails.logger.info "[#{LOG_TAG}] distributed lock held by another instance"
      false
    end
  end

  def release_distributed_lock
    result = 0
    Sidekiq.redis do |conn|
      result = conn.del(LOCK_KEY)
    end

    if result > 0
      Rails.logger.info "[#{LOG_TAG}] distributed lock released"
    else
      Rails.logger.warn "[#{LOG_TAG}] distributed lock release failed (may have expired)"
    end
  rescue StandardError => e
    Rails.logger.error "[#{LOG_TAG}] lock release error: #{e.message}"
  end

  def should_send_notification?
    Rails.env.production? && catalog_repo_sync_config[:enable_notifications]
  end

  def catalog_repo_sync_config
    Rails.application.config.x.catalog.providers.repo_sync
  end

  def send_notification(title, message, error: false)
    level = error ? :error : :info
    Rails.logger.send(level, "[#{LOG_TAG}] notification: #{title} - #{message}")
  end
end
