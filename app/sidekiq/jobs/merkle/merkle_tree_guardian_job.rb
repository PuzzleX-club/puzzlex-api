# frozen_string_literal: true

# Merkle树守护者任务 - 确保Merkle树始终保持最新状态
module Jobs::Merkle
  class MerkleTreeGuardianJob
    include Sidekiq::Job

    # 设置任务队列和重试策略
    sidekiq_options queue: :scheduler, retry: 3

    def perform
      # Leader选举检查：只有Leader实例执行Merkle树守护
      begin
        unless Sidekiq::Election::Service.leader?
          Rails.logger.debug "[MerkleTreeGuardianJob] 非Leader实例，跳过检查"
          return
        end
      rescue => e
        Rails.logger.error "[MerkleTreeGuardianJob] 选举服务异常: #{e.message}，跳过本次检查"
        return
      end

      Rails.logger.info "[MerkleTreeGuardianJob] 开始检查Merkle树状态 (Leader)"
    
      start_time = Time.current
      check_results = {}
      action_taken = false
    
      begin
        # 1. 获取所有NFT集合
        nft_collections = Merkle::TreeGenerator.get_nft_collection_item_ids
        Rails.logger.info "[MerkleTreeGuardianJob] 检查 #{nft_collections.length} 个NFT集合"
      
        nft_collections.each do |item_id|
          check_result = check_merkle_tree_status(item_id)
          check_results[item_id] = check_result
        
          if check_result[:needs_update]
            Rails.logger.warn "[MerkleTreeGuardianJob] item_id=#{item_id} 需要更新: #{check_result[:reason]}"
          
            begin
              # 异步生成新的Merkle树
              GenerateMerkleTreeJob.perform_async
              action_taken = true
              Rails.logger.info "[MerkleTreeGuardianJob] ✓ 已触发 item_id=#{item_id} 的Merkle树重新生成"
            
              # 避免同时生成太多任务，等待一下
              break
            rescue => e
              Rails.logger.error "[MerkleTreeGuardianJob] ❌ 触发 item_id=#{item_id} 生成失败: #{e.message}"
            end
          else
            Rails.logger.debug "[MerkleTreeGuardianJob] ✓ item_id=#{item_id} 状态正常"
          end
        end
      
        # 2. 检查是否需要清理过期数据
        cleanup_needed = check_cleanup_needed
        if cleanup_needed
          Rails.logger.info "[MerkleTreeGuardianJob] 检测到需要清理过期数据"
          cleanup_old_merkle_trees
          action_taken = true
        end
      
        # 3. 记录总结
        duration = Time.current - start_time
        needs_update_count = check_results.values.count { |r| r[:needs_update] }
      
        if action_taken
          Rails.logger.info "[MerkleTreeGuardianJob] 任务完成: 检查了#{nft_collections.length}个集合, " \
                           "其中#{needs_update_count}个需要更新, 耗时=#{duration.round(2)}s"
        else
          Rails.logger.debug "[MerkleTreeGuardianJob] 检查完成: 所有Merkle树状态正常, 耗时=#{duration.round(2)}s"
        end
      
      rescue => e
        Rails.logger.error "[MerkleTreeGuardianJob] 守护任务执行失败: #{e.message}"
        Rails.logger.error e.backtrace.join("\n")
      end
    end

    private

    # 检查特定item_id的Merkle树状态
    def check_merkle_tree_status(item_id)
      # 查找最新的Merkle树根节点
      latest_root = Merkle::TreeRoot.where(item_id: item_id, tree_exists: true)
                                          .order(created_at: :desc)
                                          .first

      # 如果没有找到任何Merkle树
      if latest_root.nil?
        return {
          needs_update: true,
          reason: "没有找到任何Merkle树",
          latest_root: nil,
          age_hours: nil
        }
      end

      # 计算Merkle树的年龄
      age_hours = (Time.current - latest_root.created_at) / 1.hour

      # 检查是否需要更新的条件
      needs_update = false
      reason = ""

      # 条件1: 超过18小时没有更新（比12小时定时任务多一些缓冲）
      if age_hours > 18
        needs_update = true
        reason = "超过18小时未更新 (#{age_hours.round(1)}小时前)"
      end

      # 条件2: 检查token数量是否发生显著变化（可选的高级检查）
      if !needs_update && should_check_token_count_change?
        current_token_count = get_current_token_count(item_id)
        stored_token_count = latest_root.token_count
      
        if stored_token_count && current_token_count
          change_ratio = (current_token_count - stored_token_count).abs.to_f / stored_token_count
        
          # 如果token数量变化超过5%，需要更新
          if change_ratio > 0.05
            needs_update = true
            reason = "token数量显著变化: #{stored_token_count} -> #{current_token_count} (#{(change_ratio * 100).round(1)}%)"
          end
        end
      end

      {
        needs_update: needs_update,
        reason: reason,
        latest_root: latest_root,
        age_hours: age_hours.round(1)
      }
    end

    # 获取当前item_id的实际token数量
    def get_current_token_count(item_id)
      begin
        # 使用和MerkleTreeGenerator相同的逻辑获取token数量
        market = Trading::Market.find_by(item_id: item_id)
        return nil unless market

        item = ItemIndexer::Item.find_by(id: item_id.to_s)
        return nil unless item

        # 获取当前的 instance 数量
        ItemIndexer::Instance.where(item: item_id.to_s).count
      rescue => e
        Rails.logger.error "[MerkleTreeGuardianJob] 获取 item_id=#{item_id} token数量失败: #{e.message}"
        nil
      end
    end

    # 检查是否需要进行token数量变化检查（避免过于频繁的数据库查询）
    def should_check_token_count_change?
      # 只在特定时间进行深度检查，例如每小时的第15分钟
      Time.current.min == 15
    end

    # 检查是否需要清理过期数据
    def check_cleanup_needed
      # 查找超过12天的Merkle树节点（保留时间比生成任务中的10天多一些）
      old_count = Merkle::TreeNode.where('created_at < ?', 12.days.ago).count
      old_count > 0
    end

    # 清理过期的Merkle树数据
    def cleanup_old_merkle_trees
      Rails.logger.info "[MerkleTreeGuardianJob] 开始清理过期Merkle树数据"
    
      cutoff_time = 12.days.ago
    
      old_snapshots = Merkle::TreeNode.where('created_at < ?', cutoff_time)
                                             .select(:snapshot_id)
                                             .distinct
                                             .pluck(:snapshot_id)
    
      if old_snapshots.any?
        Rails.logger.info "[MerkleTreeGuardianJob] 发现 #{old_snapshots.length} 个过期快照，开始清理"
      
        # 标记根节点为已删除
        Merkle::TreeRoot.mark_trees_as_deleted(old_snapshots)
      
        # 删除节点数据
        deleted_count = 0
        old_snapshots.each do |snapshot_id|
          count = Merkle::TreeNode.where(snapshot_id: snapshot_id).count
          Merkle::TreeNode.where(snapshot_id: snapshot_id).delete_all
          deleted_count += count
        end
      
        Rails.logger.info "[MerkleTreeGuardianJob] ✓ 清理完成，删除了 #{deleted_count} 个节点"
      else
        Rails.logger.debug "[MerkleTreeGuardianJob] 无需清理，没有过期数据"
      end
    rescue => e
      Rails.logger.error "[MerkleTreeGuardianJob] 清理失败: #{e.message}"
    end
  end end
