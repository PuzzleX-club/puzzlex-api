# frozen_string_literal: true

module Jobs
  module Indexer
    # 每日恢复永久失败的 metadata 记录
    #
    # 设计目的：
    # - InstanceMetadataScannerJob 只处理 retry_count < 3 的失败记录
    # - 本任务每天执行一次，重置永久失败记录使其重新进入恢复流程
    # - 适用于临时性错误（如网络问题、API限流、已修复的bug）
    #
    # 执行时间：每天凌晨 3:00 UTC
    class InstanceMetadataRecoveryJob
      include Sidekiq::Job

      sidekiq_options queue: :scheduler, retry: false

      def perform
        # Leader 选举检查
        unless leader?
          Rails.logger.debug "[InstanceMetadataRecoveryJob] 非Leader实例，跳过"
          return
        end

        unless metadata_enabled?
          Rails.logger.debug "[InstanceMetadataRecoveryJob] metadata功能未启用"
          return
        end

        Rails.logger.info "[InstanceMetadataRecoveryJob] 开始每日恢复任务"

        # 重置永久失败的记录（retry_count >= retry_limit）
        retry_limit = Rails.application.config.x.instance_metadata.retry_limit || 3

        reset_count = ItemIndexer::Instance
          .where(metadata_status: 'failed')
          .where('metadata_retry_count >= ?', retry_limit)
          .update_all(
            metadata_retry_count: 0,
            metadata_status: 'pending',
            metadata_status_updated_at: Time.current
          )

        Rails.logger.info "[InstanceMetadataRecoveryJob] ✅ 重置了 #{reset_count} 个永久失败记录"

        # 统计当前状态
        stats = ItemIndexer::Instance.group(:metadata_status).count
        Rails.logger.info "[InstanceMetadataRecoveryJob] 当前状态分布: #{stats}"

      rescue StandardError => e
        Rails.logger.error "[InstanceMetadataRecoveryJob] 执行失败: #{e.message}"
        Rails.logger.error e.backtrace.first(3).join("\n")
      end

      private

      def leader?
        Sidekiq::Election::Service.leader?
      rescue => e
        Rails.logger.error "[InstanceMetadataRecoveryJob] 选举服务异常: #{e.message}"
        false
      end

      def metadata_enabled?
        Rails.application.config.x.instance_metadata.enabled
      rescue
        false
      end
    end
  end
end
