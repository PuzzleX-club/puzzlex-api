# frozen_string_literal: true

module Jobs
  module Indexer
    class InstanceMetadataScannerJob
      include Sidekiq::Job
      include Throttleable

      sidekiq_options queue: :scheduler, retry: false

      throttle interval: 2.0  # 2秒内不重复执行

      def perform
        # Leader选举检查：只有Leader实例执行元数据扫描
        begin
          unless Sidekiq::Election::Service.leader?
            Rails.logger.debug "[InstanceMetadataScannerJob] 非Leader实例，跳过扫描"
            return
          end
        rescue => e
          Rails.logger.error "[InstanceMetadataScannerJob] 选举服务异常: #{e.message}，跳过本次扫描"
          return
        end

        # ⭐ 使用 Throttleable Concern 防止积压任务重复执行
        return if should_throttle?

        unless metadata_enabled?
          Rails.logger.debug "[InstanceMetadataScannerJob] metadata功能未启用，跳过扫描"
          return
        end

        # 检查 metadata_fetch 队列积压情况
        queue_size = Sidekiq::Queue.new('metadata_fetch').size
        queue_threshold = scanner_queue_threshold

        if queue_size >= queue_threshold
          Rails.logger.info "[InstanceMetadataScannerJob] metadata_fetch 队列积压 (#{queue_size}/#{queue_threshold})，跳过本次扫描"
          return
        end

        Rails.logger.info "[InstanceMetadataScannerJob] 开始扫描需要获取metadata的instances (Leader)"
        Rails.logger.info "[InstanceMetadataScannerJob] 当前队列大小: #{queue_size}/#{queue_threshold}"

        # 使用动态 batch_size（支持限流后自动调整）
        # 同时考虑队列剩余容量
        base_batch_size = Indexer::RateLimitHandler.current_batch_size
        available_capacity = queue_threshold - queue_size
        batch_size = [base_batch_size, available_capacity].min
        Rails.logger.info "[InstanceMetadataScannerJob] 当前 batch_size: #{batch_size} (base=#{base_batch_size}, capacity=#{available_capacity})"

        # 1. 原子更新 pending -> queued 并入队
        # 使用时间戳作为查询条件，确保只获取本次更新的 IDs
        now = Time.current
        updated_count = ItemIndexer::Instance
                          .pending_metadata
                          .limit(batch_size)
                          .update_all(
                            metadata_status: 'queued',
                            metadata_status_updated_at: now
                          )

        if updated_count > 0
          # 查询实际被更新的 IDs（使用时间戳匹配）
          queued_ids = ItemIndexer::Instance
                         .queued_metadata
                         .where(metadata_status_updated_at: now)
                         .limit(batch_size)
                         .pluck(:id)

          Rails.logger.info "[InstanceMetadataScannerJob] 原子更新 #{queued_ids.size} 个 pending instances 为 queued"

          queued_ids.each do |id|
            InstanceMetadataFetchJob.perform_async(id)
          end
        end

        # 2. 扫描需要重试的failed instances（同样原子更新）
        retry_limit = Rails.application.config.x.instance_metadata.retry_limit
        failed_batch_size = [batch_size / 2, 1].max

        failed_now = Time.current
        failed_updated_count = ItemIndexer::Instance
                                 .failed_metadata
                                 .where('metadata_retry_count < ?', retry_limit)
                                 .limit(failed_batch_size)
                                 .update_all(
                                   metadata_status: 'queued',
                                   metadata_status_updated_at: failed_now
                                 )

        if failed_updated_count > 0
          failed_queued_ids = ItemIndexer::Instance
                                .queued_metadata
                                .where(metadata_status_updated_at: failed_now)
                                .limit(failed_batch_size)
                                .pluck(:id)

          Rails.logger.info "[InstanceMetadataScannerJob] 原子更新 #{failed_queued_ids.size} 个 failed instances 为 queued（重试）"

          failed_queued_ids.each do |id|
            InstanceMetadataFetchJob.perform_async(id)
          end
        end

        # 3. 清理卡住的 fetching 状态（超过1小时）
        # ⚠️ 使用 metadata_status_updated_at，不是 last_updated！
        # ⚠️ 排除 NULL（旧数据，迁移前创建）
        stale_fetching = ItemIndexer::Instance
                           .fetching_metadata
                           .where.not(metadata_status_updated_at: nil)
                           .where('metadata_status_updated_at < ?', 1.hour.ago)

        if stale_fetching.any?
          count = stale_fetching.count
          Rails.logger.warn "[InstanceMetadataScannerJob] ⚠️ 发现 #{count} 个卡住的 fetching instances，重置为 pending"
          stale_fetching.update_all(
            metadata_status: 'pending',
            metadata_status_updated_at: Time.current
          )
        end

        # 4. 清理卡住的 queued 状态（超过5分钟）
        stale_queued = ItemIndexer::Instance
                         .queued_metadata
                         .where.not(metadata_status_updated_at: nil)
                         .where('metadata_status_updated_at < ?', 5.minutes.ago)

        if stale_queued.any?
          count = stale_queued.count
          Rails.logger.warn "[InstanceMetadataScannerJob] ⚠️ 发现 #{count} 个卡住的 queued instances，重置为 pending"
          stale_queued.update_all(
            metadata_status: 'pending',
            metadata_status_updated_at: Time.current
          )
        end

        Rails.logger.info "[InstanceMetadataScannerJob] 扫描完成"
      rescue StandardError => e
        Rails.logger.error "[InstanceMetadataScannerJob] 扫描异常: #{e.message}"
        Rails.logger.error e.backtrace.first(3).join("\n")
      end

      private

      def metadata_enabled?
        Rails.application.config.x.instance_metadata.enabled
      rescue StandardError
        false
      end

      def scanner_queue_threshold
        Rails.application.config.x.instance_metadata.scanner_queue_threshold || 500
      rescue StandardError
        500
      end
    end
  end
end
