# frozen_string_literal: true

module Jobs::Merkle
  class GenerateMerkleTreeJob
    include Sidekiq::Job

    sidekiq_options queue: :scheduler, retry: 2

    # @param target_item_ids [Array, nil] 指定item_id列表（切片模式），nil表示分发模式
    def perform(target_item_ids = nil)
      # 切片模式：直接执行指定item_ids的Merkle树生成
      if target_item_ids.present?
        item_ids = Array(target_item_ids).flatten.compact.map(&:to_i)
        Rails.logger.info "[GenerateMerkleTreeJob] 切片模式: 生成 #{item_ids.size} 个NFT集合的Merkle树"
        execute_for_items(item_ids)
        return
      end

      # 分发模式：Leader分发到切片队列
      begin
        unless Sidekiq::Election::Service.leader?
          Rails.logger.debug "[GenerateMerkleTreeJob] 非Leader实例，跳过分发"
          return
        end
      rescue => e
        Rails.logger.error "[GenerateMerkleTreeJob] 选举服务异常: #{e.message}，跳过本次分发"
        return
      end

      Rails.logger.info "[GenerateMerkleTreeJob] 分发模式 (Leader): 开始分发Merkle树生成任务"

      # 获取所有NFT集合item_id
      item_ids = get_nft_collection_item_ids
      Rails.logger.info "[GenerateMerkleTreeJob] 找到 #{item_ids.length} 个NFT集合"

      if item_ids.empty?
        Rails.logger.info "[GenerateMerkleTreeJob] 无NFT集合需要处理"
        return
      end

      # 初始化切片分发器
      dispatcher = Sidekiq::Sharding::Dispatcher.new('merkle_generate_')
      Rails.logger.info "[GenerateMerkleTreeJob] 📊 分发到 #{dispatcher.active_instance_count} 个实例"

      # 批量分发到切片队列（按item_id分片）
      dispatcher.dispatch_batch(self.class, item_ids)

      # Leader负责清理过期数据（全局操作，不切片）
      cleanup_old_merkle_trees
    end

    private

    def execute_for_items(item_ids)
      start_time = Time.current
      generated_count = 0
      error_count = 0

      item_ids.each do |item_id|
        begin
          result = Merkle::TreeGenerator.generate_and_persist(item_id)

          Rails.logger.info "[GenerateMerkleTreeJob] ✓ item_id=#{item_id} " \
                           "snapshot_id=#{result[:snapshot_id]} " \
                           "root=#{result[:merkle_root][0..10]}..."
          generated_count += 1
        rescue => e
          Rails.logger.error "[GenerateMerkleTreeJob] ❌ item_id=#{item_id} 生成失败: #{e.message}"
          error_count += 1
        end
      end

      duration = Time.current - start_time
      Rails.logger.info "[GenerateMerkleTreeJob] 切片完成: 成功=#{generated_count}, 失败=#{error_count}, 耗时=#{duration.round(2)}s"
    end

    # 获取所有NFT集合的item_id列表
    def get_nft_collection_item_ids
      Merkle::TreeGenerator.get_nft_collection_item_ids
    end

    # 清理超过10天的Merkle树数据（仅Leader执行）
    def cleanup_old_merkle_trees
      Rails.logger.info "[GenerateMerkleTreeJob] 开始清理过期Merkle树数据"

      cutoff_time = 10.days.ago

      old_snapshots = Merkle::TreeNode.where('created_at < ?', cutoff_time)
                                             .select(:snapshot_id)
                                             .distinct
                                             .pluck(:snapshot_id)

      if old_snapshots.any?
        Rails.logger.info "[GenerateMerkleTreeJob] 发现 #{old_snapshots.length} 个过期快照，开始删除"

        deleted_count = 0

        # 先标记根节点记录为已删除
        Merkle::TreeRoot.mark_trees_as_deleted(old_snapshots)
        Rails.logger.info "[GenerateMerkleTreeJob] ✓ 已标记 #{old_snapshots.length} 个根节点为已删除状态"

        # 然后删除实际的Merkle树数据
        old_snapshots.each do |snapshot_id|
          nodes_count = Merkle::TreeNode.where(snapshot_id: snapshot_id).count
          Merkle::TreeNode.where(snapshot_id: snapshot_id).delete_all

          Rails.logger.debug "[GenerateMerkleTreeJob] 删除快照 #{snapshot_id} (#{nodes_count} 个节点)"
          deleted_count += nodes_count
        end

        Rails.logger.info "[GenerateMerkleTreeJob] ✓ 清理完成，删除了 #{deleted_count} 个节点"
      else
        Rails.logger.info "[GenerateMerkleTreeJob] 无需清理，没有过期数据"
      end
    rescue => e
      Rails.logger.error "[GenerateMerkleTreeJob] 清理过期数据失败: #{e.message}"
    end
  end
end
