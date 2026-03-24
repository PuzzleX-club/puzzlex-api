# frozen_string_literal: true

module Jobs
  module MarketData
    module Broadcast
      class DispatcherJob
        # 重构后的主调度器：使用策略模式统一管理调度逻辑
        include Sidekiq::Job
        include ::MarketData::TimeAlignment
        include Throttleable

        sidekiq_options queue: :scheduler, retry: 2

        throttle interval: 0.5  # 500ms 防重复执行

      # 孤儿队列检查间隔（秒）
        ORPHAN_CHECK_INTERVAL = 60

      # 切片队列前缀列表
        SHARDED_QUEUE_PREFIXES = %w[order_matching depth_broadcast ticker_broadcast kline_broadcast kline_generate market_aggregate merkle_generate].freeze

        def perform
        # 只有 leader 实例才执行主调度分发
        begin
          unless Sidekiq::Election::Service.leader?
            Rails.logger.debug "[MarketData::Broadcast::DispatcherJob] 非Leader实例，跳过调度"
            return
          end
        rescue => e
          # fail-safe: 选举服务异常时记录日志并跳过
          Rails.logger.error "[MarketData::Broadcast::DispatcherJob] 选举服务异常: #{e.message}，跳过本次调度"
          return
        end

        # ⭐ 使用 Throttleable Concern 防止积压任务重复执行
        return if should_throttle?

        start_time = Time.current
        Rails.logger.info "[MarketData::Broadcast::DispatcherJob] Starting scheduling cycle (Leader)"

        # 周期性清理孤儿队列（多实例切片支持）
        check_orphan_queues_if_needed

        # 初始化检查
        ensure_initialization

        # 执行各种调度策略
        total_tasks = execute_scheduling_strategies

          Rails.logger.info "[MarketData::Broadcast::DispatcherJob] Scheduled #{total_tasks} tasks in #{(Time.current - start_time).round(3)}s"
        end

        private

      def ensure_initialization
        initialized = Sidekiq.redis { |conn| conn.get("initialization_done") }
        unless initialized
          now = Time.now

          # 使用统一的服务进行初始化
          params = {
            topic: "MARKET@1440",
            type: "MARKET",
            is_init: true,
            list_of_pairs: [["MARKET@1440", align_to_interval(now, 1440).to_i]]
          }

          Jobs::MarketData::MarketUpdateJob.perform_sync(params)

          # 设置初始化标记，带 TTL（24小时自动过期）
          Sidekiq.redis { |conn| conn.set("initialization_done", "1", ex: RuntimeCache::Keyspace::DEFAULT_INITIALIZATION_TTL) }

          Rails.logger.info "[MarketData::Broadcast::DispatcherJob] Initialization completed"
        end
      end

      def execute_scheduling_strategies
        strategies = get_scheduling_strategies
        total_tasks = 0

        strategies.each do |strategy|
          begin
            tasks = strategy.get_pending_tasks
            total_tasks += tasks.size

            # 执行任务
            execute_tasks(tasks)

          rescue => e
            Rails.logger.error "[MarketData::Broadcast::DispatcherJob] Error in #{strategy.class.name}: #{e.message}"
            Rails.logger.error e.backtrace.join("\n")
          end
        end

        total_tasks
      end

      def get_scheduling_strategies
        [
          Strategies::KlineSchedulingStrategy.new,
          Strategies::TickerSchedulingStrategy.new,
          Strategies::MarketSchedulingStrategy.new,
          Strategies::DepthSchedulingStrategy.new  # 深度心跳调度
        ]
      end

      def execute_tasks(tasks)
        tasks.each do |task|
          case task[:type]
          when 'market_update'
            Jobs::MarketData::MarketUpdateJob.perform_async(task[:params])
          when 'kline_batch', 'ticker_batch', 'depth', 'market_realtime'
            # ticker_realtime 已废弃 (2025-01)：功能已被MARKET@1440替代
            Jobs::MarketData::Broadcast::Worker.perform_async(task[:type], task[:params])
          else
            Rails.logger.warn "[MarketData::Broadcast::DispatcherJob] Unknown task type: #{task[:type]}"
          end
        end
      end

      # ========== 孤儿队列清理（多实例切片支持） ==========

      def check_orphan_queues_if_needed
        last_check_key = "sidekiq:orphan_check:last_time"
        last_check = Sidekiq.redis { |conn| conn.get(last_check_key) }.to_i

        return if Time.now.to_i - last_check < ORPHAN_CHECK_INTERVAL

        # 更新检查时间，带 TTL
        Sidekiq.redis { |conn| conn.set(last_check_key, Time.now.to_i, ex: 3600) }
        cleanup_orphan_queues
      end

      def cleanup_orphan_queues
        active_instances = Sidekiq::Cluster::InstanceRegistry.get_active_instances
        active_indices = active_instances.map { |id| id.match(/(\d+)$/)&.[](1) }.compact

        # 如果没有活跃实例（可能是单实例模式），跳过孤儿检查
        if active_instances.empty?
          Rails.logger.debug "[MarketData::Broadcast::DispatcherJob] 无活跃实例，跳过孤儿队列检查"
          return
        end

        Sidekiq::Queue.all.each do |queue|
          SHARDED_QUEUE_PREFIXES.each do |prefix|
            next unless queue.name =~ /^#{prefix}_(\d+)$/

            queue_index = $1
            next if active_indices.include?(queue_index)
            next if queue.size == 0

            Rails.logger.warn "[MarketData::Broadcast::DispatcherJob] 发现孤儿队列: #{queue.name}, 任务数: #{queue.size}"
            redistribute_orphan_queue(queue, prefix, active_indices)
          end
        end
      rescue => e
        Rails.logger.error "[MarketData::Broadcast::DispatcherJob] 孤儿队列清理失败: #{e.message}"
      end

      def redistribute_orphan_queue(queue, prefix, active_indices)
        return if active_indices.empty?

        # 使用一致性哈希重新分配
        ring = Sidekiq::Sharding::ConsistentHash.new(active_indices.map { |i| "sidekiq-#{i}" })
        redistributed_count = 0

        queue.each do |job|
          begin
            market_id = job.args.first  # 假设第一个参数是 market_id
            target_instance = ring.get_node(market_id)
            target_index = target_instance.match(/(\d+)$/)&.[](1) || '0'
            target_queue = "#{prefix}_#{target_index}"

            # 重新入队到目标队列
            job.klass.constantize.set(queue: target_queue).perform_async(*job.args)
            job.delete
            redistributed_count += 1
          rescue => e
            Rails.logger.error "[MarketData::Broadcast::DispatcherJob] 重分发任务失败: #{e.message}"
          end
        end

        Rails.logger.info "[MarketData::Broadcast::DispatcherJob] 孤儿队列 #{queue.name} 已重分发 #{redistributed_count} 个任务到活跃实例"
      end
    end
  end
end
end
