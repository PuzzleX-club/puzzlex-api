# frozen_string_literal: true

module Sidekiq
  module Sharding
    # 通用一致性哈希分发器（按任意 key 切片）
    # 根据 key 使用一致性哈希将任务分发到对应的Sidekiq实例队列
    class Dispatcher
    attr_reader :queue_prefix

    # @param queue_prefix [String] 队列前缀（如 "order_matching_"）
    def initialize(queue_prefix)
      @queue_prefix = queue_prefix
      refresh_ring
    end

    # 刷新哈希环（获取最新的活跃实例列表）
    def refresh_ring
      all_instances = Sidekiq::Cluster::InstanceRegistry.get_active_instances
      # 过滤掉 Leader (sidekiq-0)，只保留 Worker
      # Leader 负责调度任务，不执行切片任务
      @instances = all_instances.reject { |id| id.end_with?('-0') }
      @ring = ConsistentHash.new(@instances)
    end

    # 分发单个市场任务
    # @param job_class [Class] Sidekiq Job类
    # @param market_id [Integer, String] 市场ID
    # @param args [Array] 其他参数
    # @return [String, nil] Job ID
    def dispatch(job_class, shard_key, *args)
      return fallback_dispatch(job_class, shard_key, args) if @instances.empty?

      target_instance = @ring.get_node(shard_key)
      target_queue = "#{@queue_prefix}#{instance_index(target_instance)}"

      job_class.set(queue: target_queue).perform_async(shard_key, *args)
    end

    # 批量分发任务
    # @param job_class [Class] Sidekiq Job类
    # @param shard_keys [Array<Integer, String>] 切片 key 列表
    # @param common_args [Array] 公共参数
    def dispatch_batch(job_class, shard_keys, *common_args)
      refresh_ring # 每次批量分发前刷新实例列表

      shard_keys.each do |shard_key|
        dispatch(job_class, shard_key, *common_args)
    end
  end
end

    # 获取市场到实例的映射关系（用于调试）
    # @param shard_keys [Array<Integer, String>] 切片 key 列表
    # @return [Hash] { market_id => queue_name }
    def market_queue_mapping(shard_keys)
      refresh_ring
      return {} if @instances.empty?

      shard_keys.each_with_object({}) do |shard_key, result|
        target_instance = @ring.get_node(shard_key)
        result[shard_key] = "#{@queue_prefix}#{instance_index(target_instance)}"
      end
    end

    # 获取当前活跃实例数量
    def active_instance_count
      @instances.size
    end

    # 获取当前活跃实例列表
    def active_instances
      @instances.dup
    end

    private

    # 从实例ID提取索引
    # @param instance_id [String] 实例ID（如 "sidekiq-2" 或 "puzzlex-sidekiq-2"）
    # @return [String] 实例索引
    def instance_index(instance_id)
      match = instance_id.match(/(\d+)$/)
      if match
        match[1]
      else
        Sidekiq.logger.warn "[Sharding] 无法解析实例索引: #{instance_id}, 使用hash降级"
        (instance_id.hash.abs % 1000).to_s
      end
    end

    # 无活跃实例时的降级分发
    # @param job_class [Class] Sidekiq Job类
    # @param market_id [Integer, String] 市场ID
    # @param args [Array] 其他参数
    # @return [String, nil] Job ID
    def fallback_dispatch(job_class, shard_key, args)
      Sidekiq.logger.warn "[Sharding] 无活跃实例，任务降级到默认队列: #{job_class.name}"
      job_class.perform_async(shard_key, *args)
    end
  end

end
