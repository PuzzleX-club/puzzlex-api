
module Jobs::Matching
  class DispatcherJob
    include Sidekiq::Job

    sidekiq_options queue: :scheduler, retry: 2

    def perform
      # Leader选举检查：只有Leader实例执行调度分发
      begin
        unless Sidekiq::Election::Service.leader?
          Rails.logger.debug "[Matching::Dispatcher] 非Leader实例，跳过调度"
          return
        end
      rescue => e
        # fail-safe: 选举服务异常时记录日志并跳过
        Rails.logger.error "[Matching::Dispatcher] 选举服务异常: #{e.message}，跳过本次调度"
        return
      end

      Rails.logger.info "[Matching::Dispatcher] 开始定时撮合扫描 (Leader)"

      at_exit { clean_up_redis }

      # 初始化前置验证器
      @pre_validator = Matching::State::OrderPreValidator.new

      # 设置初始化校验，在redis中保存一个marcher的key，如果没有的话，就运行初始化，如果这个key是true，就跳过初始化
      # 如果尚未初始化，则先做一次"初始化填充Redis"
      initialized = Sidekiq.redis { |conn| conn.get("orderMatcherInitialized") }
      unless initialized
        Rails.logger.info "[Matching::Dispatcher] 首次运行，调用 MarketRegistryJob 进行初始化"
        Jobs::MarketData::Sync::MarketRegistryJob.new.perform
        # 设置标记，后面就不再重复
        Sidekiq.redis { |conn| conn.set("orderMatcherInitialized", "1") }
      end

      # 从Redis Set获取所有市场ID (替代KEYS命令，性能提升10-100倍)
      market_ids = Sidekiq.redis { |conn| conn.smembers("market_list") }
      Rails.logger.info "[Matching::Dispatcher] 扫描 #{market_ids.size} 个市场"

      # 初始化市场切片分发器
      dispatcher = Sidekiq::Sharding::Dispatcher.new('order_matching_')
      Rails.logger.info "[Matching::Dispatcher] 活跃实例: #{dispatcher.active_instance_count}"

      market_ids.each do |market_id|
        # 构建市场的Redis key
        key = "orderMatcher:#{market_id}"

        # 容错处理: 检查市场key是否存在
        key_exists = Sidekiq.redis { |conn| conn.exists(key) }
        unless key_exists
          Rails.logger.warn "[Matching::Dispatcher] 市场 #{market_id} 的Redis key不存在，跳过(将由MarketRegistryJob修复)"
          next
        end

        # 从redis中获取status
        status = Sidekiq.redis { |conn| conn.hget(key, "status") }
        Rails.logger.debug "[Matching::Dispatcher] 市场 #{market_id} 状态: #{status}"

        # 处理confirming状态
        if status == 'confirming'
          # 获取存储在 Redis 中的订单哈希，假设它存储的是一个 JSON 数组
          confirming_orders = Sidekiq.redis { |conn| conn.hget(key, 'orders_hash') }

          # 如果没有订单数据则直接跳过
          next if confirming_orders.nil?

          # 转换为 Ruby 数组（如果确认是 JSON 格式存储）
          confirming_orders = JSON.parse(confirming_orders) unless confirming_orders.is_a?(Array)

          # 检查所有订单是否都为 filled
          all_filled = confirming_orders.all? do |order_hash|
            order = Trading::Order.find_by(order_hash: order_hash)
            order && order.onchain_status == 'filled'
          end

          if all_filled
            # 所有订单都填充完毕，则重置该 Redis 哈希中的字段
            Sidekiq.redis do |conn|
              conn.hset(key, "status", "waiting")
              conn.hdel(key, "orders_hash")
              conn.hdel(key, "orders")
              conn.hdel(key, "fulfillments")
            end
            status = "waiting"  # 更新本地变量以便后续判断
          end
        end

        # ✅ 改进：基于active订单数量调度，而非仅依赖市场status
        should_schedule = should_schedule_market?(market_id, status)

        # ✅ 新增：验证市场的 active 订单
        validate_market_orders(market_id)

        if should_schedule
          Rails.logger.info "[Matching::Dispatcher] 调度市场 #{market_id} 撮合任务 (status=#{status})"
          # 通过切片分发器分发到对应实例的队列
          dispatcher.dispatch(Jobs::Matching::Worker, market_id, 'scheduled')
        end
      end

    end

    private

    # ✅ 新增：智能判断是否应该调度市场
    # 基于active订单数量而不是仅依赖市场status
    def should_schedule_market?(market_id, status)
      # 1. waiting状态直接调度（保持原有逻辑）
      return true if status == "waiting"

      # 2. 对于error/idle/nil状态，检查是否有active订单
      # 如果有active订单，应该恢复调度
      if status.nil? || status == "error" || status == "idle"
        active_count = count_active_orders(market_id)

        if active_count > 0
          # 有active订单，重置状态并调度
          Rails.logger.info "[Matching::Dispatcher] 市场#{market_id}状态#{status}但有#{active_count}个active订单，重置为waiting"
          reset_market_to_waiting(market_id)
          return true
        else
          # 无active订单，不调度
          Rails.logger.debug "[Matching::Dispatcher] 市场#{market_id}无active订单，跳过调度"
          return false
        end
      end

      # 3. matched/confirming状态暂不调度
      false
    end

    # 计算市场中active订单数量
    def count_active_orders(market_id)
      Trading::Order.where(
        market_id: market_id,
        offchain_status: 'active'
      ).where(onchain_status: %w[pending validated partially_filled]).count
    end

    # 重置市场状态为waiting
    def reset_market_to_waiting(market_id)
      key = "orderMatcher:#{market_id}"
      Sidekiq.redis do |conn|
        conn.hset(key, "status", "waiting")
        # 清除错误信息
        conn.hdel(key, "error_at", "error_message", "error_reason", "error_location", "error_count")
      end
    end

    # ✅ 新增：验证市场的 active 订单
    # 将验证失败的订单标记为 validation_failed 状态
    def validate_market_orders(market_id)
      # 只查询需要验证的订单（active 状态且 order_status 为 pending、validated 或 partially_filled）
      orders = Trading::Order.where(
        market_id: market_id,
        offchain_status: 'active'
      ).where(onchain_status: %w[pending validated partially_filled])

      return if orders.empty?

      Rails.logger.info "[Matching::Dispatcher] 市场 #{market_id} 有 #{orders.count} 个 active 订单待验证"

      orders.each do |order|
        result = @pre_validator.validate(order)

        unless result[:valid]
          # 验证失败，更新状态和原因
          reason = result[:reason]
          Orders::OrderStatusManager.new(order).set_offchain_status!(
            'validation_failed',
            reason
          )
          Rails.logger.info "[Matching::Dispatcher] 订单 #{order.order_hash[0..12]}... 验证失败: #{reason}"
        end
      end
    end

    def clean_up_redis
      # 在这里加入你需要删除的 Redis 键或清理逻辑
      Rails.logger.info "Cleaning up Redis..."
      # todo:需要根据实际情况添加需要清理的redis key
      Sidekiq.redis { |conn| conn.del('orderMatcherInitialized') }

      Rails.logger.info "Cleaned up orderMatcher keys from Redis."
      order_matcher_keys = Sidekiq.redis { |conn| conn.keys("orderMatcher:*") } # 依据命名规则调整模式

      # 删除与 next_aligned_ts 相关的键
      Sidekiq.redis { |conn| conn.del(*order_matcher_keys) } unless order_matcher_keys.empty?

    end
  end
end
