# frozen_string_literal: true

module Jobs::Matching
  class TimeoutJob
    include Sidekiq::Job

    sidekiq_options retry: 3, queue: 'scheduler'

    def perform
      # Leader选举检查：只有Leader实例执行超时检查
      begin
        unless Sidekiq::Election::Service.leader?
          Rails.logger.debug "[Matching::Timeout] 非Leader实例，跳过超时检查"
          return
        end
      rescue => e
        # fail-safe: 选举服务异常时记录日志并跳过
        Rails.logger.error "[Matching::Timeout] 选举服务异常: #{e.message}，跳过本次检查"
        return
      end

      Rails.logger.info "[Matching::Timeout] 开始检查超时的matching状态订单 (Leader)"
    
      # 查找超过30秒仍在matching状态的订单
      timeout_threshold = 30.seconds.ago
      stuck_orders = Trading::Order.where(
        offchain_status: 'matching'
      )
      .where('offchain_status_updated_at <= ?', timeout_threshold)
    
      if stuck_orders.empty?
        Rails.logger.debug "[Matching::Timeout] 没有超时的matching订单"
        return
      end

      Rails.logger.warn "[Matching::Timeout] 找到 #{stuck_orders.count} 个超时的matching订单"
    
      # 按市场分组处理
      orders_by_market = stuck_orders.group_by(&:market_id)
    
      orders_by_market.each do |market_id, orders|
        process_stuck_orders(market_id, orders)
      end
    
      Rails.logger.info "[Matching::Timeout] 超时订单处理完成"
    end
  
    private
  
    def process_stuck_orders(market_id, orders)
      Rails.logger.info "[Matching::Timeout] 处理市场 #{market_id} 的 #{orders.size} 个超时订单"
    
      # 创建超时清理日志记录器
      logger = Matching::State::Logger.new(market_id, 'timeout_cleanup')
    
      order_hashes = orders.map(&:order_hash)
      timeout_threshold = 30.seconds.ago
    
      # 记录超时清理操作
      logger.log_timeout_cleanup(order_hashes, timeout_threshold)
    
      # 加入失败队列进行智能恢复
      failed_queue_key = "match_failed_queue:#{market_id}"
      recovery_data = {
        order_hashes: order_hashes,
        failed_at: Time.current.to_f,
        error: 'matching_timeout',
        error_class: 'Timeout::Error',
        market_id: market_id,
        source: 'match_timeout',
        reason: 'matching_timeout'
      }
    
      Sidekiq.redis do |conn|
        conn.lpush(failed_queue_key, recovery_data.to_json)
        conn.expire(failed_queue_key, 3600) # 1小时过期
      end
    
      # 设置为paused状态
      paused_count = 0
      orders.each do |order|
        begin
          old_status = order.offchain_status
          Orders::OrderStatusManager.new(order).set_offchain_status!(
            'paused',
            'matching_timeout'
          )
        
          # 记录状态转换
          logger.log_queue_exit([order.order_hash], 'timeout_paused', 'recovery_queue')
        
          Rails.logger.info "[Matching::Timeout] 订单 #{order.order_hash}: #{old_status} → paused（超时）"
          paused_count += 1
        rescue => e
          Rails.logger.error "[Matching::Timeout] 处理订单 #{order.order_hash} 失败: #{e.message}"
        end
      end
    
      # 清理可能残留的Redis数据
      clear_stuck_redis_data(market_id)
    
      # 完成超时清理会话
      logger.log_session_success({ 
        description: "超时清理完成",
        paused_orders: paused_count,
        total_orders: orders.size 
      })
    
      Rails.logger.info "[Matching::Timeout] 市场 #{market_id} 的超时订单已加入恢复队列: #{paused_count}/#{orders.size}"
    end
  
    def clear_stuck_redis_data(market_id)
      begin
        redis_key = "orderMatcher:#{market_id}"
        status = Sidekiq.redis { |conn| conn.hget(redis_key, "status") }

        # 如果Redis中还是matched或confirming状态，重置为waiting
        if %w[matched confirming].include?(status)
          Rails.logger.warn "[Matching::Timeout] 清理市场 #{market_id} 的残留Redis数据 (status=#{status})"

          Sidekiq.redis do |conn|
            conn.multi do |redis|
              redis.hset(redis_key, "status", "waiting")
              redis.hdel(redis_key, "orders")
              redis.hdel(redis_key, "fulfillments")
              redis.hdel(redis_key, "orders_hash")
              redis.hset(redis_key, "timeout_cleared_at", Time.current.to_f.to_s)
            end
          end
        end
      rescue => e
        Rails.logger.error "[Matching::Timeout] 清理Redis数据失败: #{e.message}"
      end
    end
  end
end
