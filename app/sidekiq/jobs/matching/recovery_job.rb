# frozen_string_literal: true

module Jobs::Matching
  class RecoveryJob
    include Sidekiq::Job

    sidekiq_options retry: 3, queue: 'critical'

    def perform
      # Leader选举检查：只有Leader实例执行恢复任务
      begin
        unless Sidekiq::Election::Service.leader?
          Rails.logger.debug "[Matching::Recovery] 非Leader实例，跳过恢复任务"
          return
        end
      rescue => e
        # fail-safe: 选举服务异常时记录日志并跳过
        Rails.logger.error "[Matching::Recovery] 选举服务异常: #{e.message}，跳过本次恢复"
        return
      end

      Rails.logger.info "[Matching::Recovery] 开始处理失败订单恢复任务 (Leader)"

      orders = fetch_paused_orders
      if orders.empty?
        Rails.logger.debug "[Matching::Recovery] 没有需要恢复的暂停订单"
        return
      end

      total_recovered = 0
      orders.group_by(&:market_id).each do |market_id, market_orders|
        total_recovered += process_paused_orders(market_id, market_orders)
      end

      Rails.logger.info "[Matching::Recovery] 失败订单恢复任务完成，共恢复 #{total_recovered} 个订单"
    end
  
    private

    RESCAN_THRESHOLD = 30.seconds
    BATCH_SIZE = 50
    RECOVERABLE_REASONS = %w[
      matching_failed_hard
      matching_failed_soft
      matching_timeout
      matching_failed_pending_recovery
    ].freeze

    def fetch_paused_orders
      Trading::Order
        .where(offchain_status: 'paused', offchain_status_reason: RECOVERABLE_REASONS)
        .where('offchain_status_updated_at <= ?', RESCAN_THRESHOLD.ago)
        .order(:offchain_status_updated_at)
        .limit(BATCH_SIZE)
    end

    def process_paused_orders(market_id, orders)
      order_hashes = orders.map(&:order_hash)
      Rails.logger.info "[Matching::Recovery] 处理市场#{market_id}暂停订单: #{order_hashes.size}"

      logger = Matching::State::Logger.new(market_id, "recovery_paused_scan")
    
      # 批量检查链上状态
      chain_statuses = batch_check_chain_status(order_hashes)
      recovered_count = 0
    
      order_hashes.each_with_index do |order_hash, index|
        begin
          order = Trading::Order.find_by(order_hash: order_hash)
          unless order
            Rails.logger.warn "[Matching::Recovery] 订单不存在: #{order_hash}"
            next
          end
        
          # 如果订单不是paused状态，跳过（可能已被其他途径处理）
          unless order.offchain_status == 'paused'
            Rails.logger.debug "[Matching::Recovery] 订单 #{order_hash} 不是paused状态(#{order.offchain_status})，跳过"
            next
          end
        
          chain_status = chain_statuses[index]
        
          # 智能决定恢复状态
          new_status = determine_recovery_status(order, chain_status)

          if new_status == 'paused'
            Rails.logger.debug "[Matching::Recovery] 订单 #{order_hash} 仍保持paused"
            next
          end

          old_status = order.offchain_status
          Orders::OrderStatusManager.new(order).set_offchain_status!(
            new_status,
            'recovered_from_matching_failure'
          )

          logger.log_recovery_attempt([order_hash], 'paused_scan', "#{old_status} → #{new_status}")

          if new_status == 'active'
            Rails.logger.info "[Matching::Recovery] 订单 #{order_hash} 恢复: #{old_status} → #{new_status}"
            recovered_count += 1
          end

        rescue => e
          Rails.logger.error "[Matching::Recovery] 处理订单 #{order_hash} 失败: #{e.message}"
        end
      end
    
      # 完成恢复会话
      if recovered_count > 0
        logger.log_session_success({
          description: "恢复成功",
          recovered_orders: recovered_count,
          total_orders: order_hashes.size
        })

        # ✅ 新增：确保市场状态可调度
        ensure_market_schedulable(market_id)
      else
        logger.log_session_cancelled("所有订单恢复失败或无需恢复")
      end

      recovered_count
    end

    def batch_check_chain_status(order_hashes)
      Rails.logger.debug "[Matching::Recovery] 批量检查 #{order_hashes.size} 个订单的链上状态"
    
      # 批量RPC调用，减少网络开销
      contract_service = Seaport::ContractService.new
    
      order_hashes.map do |order_hash|
        begin
          status = contract_service.get_order_status(order_hash)
          Rails.logger.debug "[Matching::Recovery] 订单 #{order_hash} 链上状态: validated=#{status[:is_validated]}, cancelled=#{status[:is_cancelled]}, filled=#{status[:total_filled]}/#{status[:total_size]}"
          status
        rescue => e
          Rails.logger.error "[Matching::Recovery] 检查订单 #{order_hash} 链上状态失败: #{e.message}"
          { error: e.message }
        end
      end
    end
  
    def determine_recovery_status(order, chain_status)
      Rails.logger.debug "[Matching::Recovery] 决定订单 #{order.order_hash} 的恢复状态"
    
      # 1. 检查是否有链上错误
      if chain_status[:error]
        Rails.logger.warn "[Matching::Recovery] 链上查询失败，保持paused状态: #{chain_status[:error]}"
        return 'paused'
      end
    
      # 2. 检查链上是否已成交
      total_filled = chain_status[:total_filled].to_i
      total_size = chain_status[:total_size].to_i
    
      if total_size > 0 && total_filled >= total_size
        Rails.logger.info "[Matching::Recovery] 订单已在链上成交 (#{total_filled}/#{total_size})"
        Orders::OrderStatusManager.new(order).update_onchain_status!(
          is_validated: chain_status[:is_validated],
          is_cancelled: chain_status[:is_cancelled],
          total_filled: total_filled,
          total_size: total_size,
          reason: 'match_recovery_sync'
        )
        return 'closed'
      end
    
      # 3. 检查是否部分成交
      if total_filled > 0 && total_filled < total_size
        Rails.logger.info "[Matching::Recovery] 订单已部分成交 (#{total_filled}/#{total_size})"
        Orders::OrderStatusManager.new(order).update_onchain_status!(
          is_validated: chain_status[:is_validated],
          is_cancelled: chain_status[:is_cancelled],
          total_filled: total_filled,
          total_size: total_size,
          reason: 'match_recovery_sync'
        )
        # 部分成交的订单可以继续撮合
        return check_balance_and_expire(order) ? 'active' : 'over_matched'
      end
    
      # 4. 检查是否已取消
      if chain_status[:is_cancelled]
        Rails.logger.info "[Matching::Recovery] 订单已在链上取消"
        Orders::OrderStatusManager.new(order).update_onchain_status!(
          is_validated: chain_status[:is_validated],
          is_cancelled: true,
          total_filled: total_filled,
          total_size: total_size,
          reason: 'match_recovery_sync'
        )
        return 'closed'
      end
    
      # 5. 检查是否过期
      if order.end_time.present? && 
         order.end_time != Rails.application.config.x.blockchain.seaport_max_uint256 &&
         Time.current.to_i >= order.end_time.to_i
        Rails.logger.info "[Matching::Recovery] 订单已过期"
        return 'expired'
      end
    
      # 6. 检查余额（避免死循环）
      if !check_balance_sufficient(order)
        Rails.logger.info "[Matching::Recovery] 订单余额不足"
        return 'over_matched'
      end
    
      # 7. 默认恢复为active
      Rails.logger.info "[Matching::Recovery] 订单恢复为active状态"
      'active'
    end

    def check_balance_and_expire(order)
      # 检查是否过期
      if order.end_time.present? && 
         order.end_time != Rails.application.config.x.blockchain.seaport_max_uint256 &&
         Time.current.to_i >= order.end_time.to_i
        return false
      end
    
      # 检查余额
      check_balance_sufficient(order)
    end
  
    def check_balance_sufficient(order)
      begin
        result = Matching::OverMatch::Detection.check_order_balance_and_approval(order)
        Rails.logger.debug "[Matching::Recovery] 余额/授权检查: order=#{order.order_hash}, required=#{result[:required]}, available=#{result[:available]}, sufficient=#{result[:sufficient]}, reason=#{result[:reason]}"
        result[:sufficient]
      rescue => e
        Rails.logger.error "[Matching::Recovery] 检查余额失败: #{e.message}"
        true # 余额检查失败时，默认认为充足，避免误判
      end
    end
  
    # ✅ 新增：确保市场可调度
    # 当订单恢复后，检查市场是否有active订单，如有则重置市场状态为waiting
    def ensure_market_schedulable(market_id)
      begin
        # 检查该市场是否有active订单
        active_count = Trading::Order.where(
          market_id: market_id,
          offchain_status: 'active'
        ).where(onchain_status: %w[pending validated partially_filled]).count

        if active_count > 0
          market_key = "orderMatcher:#{market_id}"
          current_status = Sidekiq.redis { |conn| conn.hget(market_key, "status") }

          # 如果状态是error或idle，更新为waiting
          if current_status != 'waiting' && current_status != 'matched'
            Sidekiq.redis do |conn|
              conn.hset(market_key, "status", "waiting")
              # 清除错误信息
              conn.hdel(market_key, "error_at", "error_message", "error_reason", "error_location", "error_count")
            end

            Rails.logger.info "[Matching::Recovery] 市场#{market_id}有#{active_count}个active订单，状态从#{current_status}重置为waiting"
          else
            Rails.logger.debug "[Matching::Recovery] 市场#{market_id}状态正常(#{current_status})，无需重置"
          end
        else
          Rails.logger.debug "[Matching::Recovery] 市场#{market_id}无active订单，保持当前状态"
        end
      rescue => e
        Rails.logger.error "[Matching::Recovery] 确保市场可调度失败: #{e.message}"
      end
    end
  end
end
