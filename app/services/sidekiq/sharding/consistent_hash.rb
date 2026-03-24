# frozen_string_literal: true

require 'digest'

module Sidekiq
  module Sharding
    # 一致性哈希算法实现
    # 用于将市场ID均匀分配到Sidekiq实例
    # 扩缩容时只迁移约1/N的市场
    class ConsistentHash
    VIRTUAL_NODES = 150  # 每个实例的虚拟节点数，提高分布均匀性

    def initialize(nodes = [])
      @ring = {}
      @sorted_keys = []
      nodes.each { |node| add_node(node) }
    end

    # 添加节点到哈希环
    # @param node [String] 节点标识（如 "sidekiq-0"）
    def add_node(node)
      VIRTUAL_NODES.times do |i|
        key = hash_key("#{node}:#{i}")
        @ring[key] = node
      end
      @sorted_keys = @ring.keys.sort
    end

    # 从哈希环移除节点
    # @param node [String] 节点标识
    def remove_node(node)
      VIRTUAL_NODES.times do |i|
        key = hash_key("#{node}:#{i}")
        @ring.delete(key)
      end
      @sorted_keys = @ring.keys.sort
    end

    # 根据 market_id 找到负责的节点
    # @param market_id [Integer, String] 市场ID
    # @return [String, nil] 负责的节点标识，无节点时返回nil
    def get_node(market_id)
      return nil if @ring.empty?

      key = hash_key(market_id.to_s)

      # 二分查找第一个大于等于key的位置
      idx = @sorted_keys.bsearch_index { |k| k >= key }
      idx ||= 0  # 如果没找到，回到环的开头

      @ring[@sorted_keys[idx]]
    end

    # 获取所有节点
    # @return [Array<String>] 唯一节点列表
    def nodes
      @ring.values.uniq
    end

    # 检查哈希环是否为空
    def empty?
      @ring.empty?
    end

    # 获取哈希环大小（包含虚拟节点）
    def size
      @ring.size
    end

    # 获取实际节点数量
    def node_count
      nodes.size
    end

    # 批量获取节点映射
    # @param market_ids [Array<Integer, String>] 市场ID列表
    # @return [Hash] { market_id => node }
    def get_nodes_for_markets(market_ids)
      market_ids.each_with_object({}) do |market_id, result|
        result[market_id] = get_node(market_id)
      end
    end

    # 按节点分组市场
    # @param market_ids [Array<Integer, String>] 市场ID列表
    # @return [Hash] { node => [market_ids] }
    def group_markets_by_node(market_ids)
      market_ids.group_by { |market_id| get_node(market_id) }
    end

    private

    # 计算哈希值
    # @param str [String] 输入字符串
    # @return [Integer] 哈希值
    def hash_key(str)
      Digest::MD5.hexdigest(str).to_i(16)
    end
    end
  end
end
