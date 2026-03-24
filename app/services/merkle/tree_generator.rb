# app/services/merkle/tree_generator.rb
require 'eth'

module Merkle
  class TreeGenerator
    # 使用 Eth::Util.keccak256 计算哈希，并转换为 "0x" 开头的十六进制字符串
    def self.keccak256_hex(binary_data)
      hash_bin = Eth::Util.keccak256(binary_data)
      "0x" + hash_bin.unpack1("H*")
    end

    # 计算叶子节点的哈希：先将 element 转换为十六进制字符串，
    # 移除前导 "0x" 后补足至 64 位，再转成二进制后计算 keccak256
    # leaf是token id,需要转换为16进制，并补全前导的0，才可以对齐seaport的合约验证
    def self.hash_leaf(element)
      hex_str = element.to_i.to_s(16)        # 得到类似 "0x..." 的字符串
      normalized = hex_str.rjust(64, '0')     # 移除前导 "0x"，并补足 64 位
      binary_data = [normalized].pack("H*")         # 转换为二进制数据
      keccak256_hex(binary_data)
    end

    # 计算两个节点组合后的父节点哈希：
    # 分别移除 a、b 的 "0x" 前缀，再按升序排序、拼接，然后转为二进制后计算 keccak256
    def self.hash_pair(a, b)
      a_norm = a.start_with?("0x") ? a[2..-1] : a
      b_norm = b.start_with?("0x") ? b[2..-1] : b
      sorted = [a_norm, b_norm].sort
      combined = sorted.join
      binary_data = [combined].pack("H*")
      keccak256_hex(binary_data)
    end

    # 构造 Merkle 树，返回一个 Hash 包含 :layers 和 :root
    # layers 是一个二维数组，每一层存储该层所有节点的哈希，从叶子层开始到根层
    # 叶子节点是一个 Hash 对象，包含 :hash 和 :token_id 信息
    # 每一层返回一个数组，每个元素为 { hash: "0x...", token_id: <token_id_or_nil> }
    def self.build_tree(elements)
      # 构造叶子节点，每个元素是一个 Hash，token_id 保留原始 token 信息
      leaves = elements.map { |e| { hash: hash_leaf(e), token_id: e } }
      layers = [leaves]
      current_layer = leaves.dup

      while current_layer.size > 1
        next_layer = []
        current_layer.each_slice(2) do |pair|
          # 如果节点数量为奇数，则复制最后一个节点
          pair << pair.first if pair.size < 2
          # 计算父节点的哈希值，注意这里只使用子节点的 :hash 字段
          parent_hash = hash_pair(pair[0][:hash], pair[1][:hash])
          # 对于内部节点，不保留 token_id 信息
          next_layer << { hash: parent_hash, token_id: nil }
        end
        layers << next_layer
        current_layer = next_layer
      end

      { layers: layers, root: layers.last.first[:hash] }
    end

    # 将 Merkle 树的各节点信息持久化到数据库
    # snapshot_id: 当前 Merkle 树的版本标识，例如 "#{item_id}-#{Time.current.to_i}"
    # layers: build_tree 返回的 layers 数组
    # item_id: 对应的 item_id
    # tree_height: 树的高度
    # token_count: token总数
    def self.persist_tree(snapshot_id, item_id, layers, tree_height, token_count)
      Merkle::TreeNode.transaction do
        layers.each_with_index do |layer, level|
          layer.each_with_index do |node, index|
            # 父节点索引仅对非叶子层有效，使用整数除法（自动向下取整）
            parent_index = (index / 2)
            # 对于根节点（最后一层），记录 item_id 和树的统计信息
            is_root = (level == layers.size - 1 && index == 0)
            record_item_id = is_root ? item_id : nil
            record_tree_height = is_root ? tree_height : nil
            record_total_tokens = is_root ? token_count : nil

            Merkle::TreeNode.create!(
              snapshot_id: snapshot_id,
              node_index: index,
              level: level,
              node_hash: node[:hash],
              parent_index: parent_index,
              is_leaf: (level == 0),
              is_root: is_root,
              token_id: node[:token_id],
              item_id: record_item_id,
              tree_height: record_tree_height,
              total_tokens: record_total_tokens
            )
          end
        end
      end
    end

    # 主方法：生成某个 item 的 Merkle 树，并持久化保存
    # 返回一个 Hash 包含 :snapshot_id, :merkle_root, :token_count
    def self.generate_and_persist(item_id)
      start_time = Time.current
      Rails.logger.info "[MerkleTreeGenerator] 开始为 item_id=#{item_id} 生成Merkle树"
      
      # 设置超时保护
      timeout_seconds = Rails.configuration.x.merkle_tree.timeout_seconds
      Timeout::timeout(timeout_seconds) do
        
        # 获取该item_id下所有的NFT token
        tokens = get_tokens_for_item(item_id)
        
        if tokens.empty?
          Rails.logger.warn "[MerkleTreeGenerator] item_id=#{item_id} 没有找到任何token"
          raise "item_id #{item_id} 没有找到对应的token"
        end
        
        # 检查token数量是否超过限制
        max_tokens = Rails.configuration.x.merkle_tree.max_tokens_per_tree
        if tokens.length > max_tokens
          Rails.logger.error "[MerkleTreeGenerator] item_id=#{item_id} token数量 #{tokens.length} 超过最大限制 #{max_tokens}"
          raise "token数量 #{tokens.length} 超过系统限制 #{max_tokens}，请联系管理员"
        end
        
        Rails.logger.info "[MerkleTreeGenerator] item_id=#{item_id} 找到 #{tokens.length} 个token"
        
        # 验证token格式
        validate_tokens(tokens)
        
        # 构建Merkle树
        tree_data = build_tree(tokens)
        snapshot_id = "#{item_id}-#{Time.current.to_i}"
        merkle_root = tree_data[:root]
        tree_height = tree_data[:layers].length
        generation_end_time = Time.current
        duration_ms = ((generation_end_time - start_time) * 1000).round
        
        # 在事务中同时保存Merkle树数据和根节点记录
        Merkle::TreeNode.transaction do
          # 持久化Merkle树到数据库
          persist_tree(snapshot_id, item_id, tree_data[:layers], tree_height, tokens.length)
          
          # 创建根节点记录
          metadata = {
            snapshot_created_at: Time.current.iso8601,
            generation_duration_ms: duration_ms,
            token_list_sample: tokens.first(5), # 保存前5个token作为样本
            total_layers: tree_height,
            algorithm_version: "v1.0",
            batch_processing_used: tokens.length > 1000
          }
          
          Merkle::TreeRoot.create!(
            root_hash: merkle_root,
            item_id: item_id,
            snapshot_id: snapshot_id,
            token_count: tokens.length,
            tree_exists: true,
            tree_height: tree_height,
            generation_duration_ms: duration_ms,
            expires_at: Time.current + 10.days,
            metadata: metadata.to_json
          )
        end
        
        Rails.logger.info "[MerkleTreeGenerator] ✓ item_id=#{item_id} Merkle树生成完成: " \
                         "snapshot_id=#{snapshot_id}, root=#{merkle_root[0..10]}..., " \
                         "token_count=#{tokens.length}, height=#{tree_height}, duration=#{duration_ms}ms"
        
        { 
          snapshot_id: snapshot_id, 
          merkle_root: merkle_root,
          token_count: tokens.length,
          tree_height: tree_height,
          generation_duration_ms: duration_ms
        }
      end
      
    rescue Timeout::Error
      Rails.logger.error "[MerkleTreeGenerator] item_id=#{item_id} 生成超时 (#{timeout_seconds}秒)"
      raise "Merkle树生成超时，可能数据量过大"
    rescue => e
      Rails.logger.error "[MerkleTreeGenerator] item_id=#{item_id} 生成失败: #{e.message}"
      raise e
    end

    private

    # 获取指定 item_id 下的所有 NFT token
    # 通过 canonical ItemIndexer::* 模型访问底层索引表。
    def self.get_tokens_for_item(item_id)
      Rails.logger.info "[MerkleTreeGenerator] 开始获取 item_id=#{item_id} 的所有token"

      # 获取该item的所有instance
      instances = ItemIndexer::Instance.where(item: item_id)
      total_count = instances.count

      if total_count == 0
        Rails.logger.warn "[MerkleTreeGenerator] item_id=#{item_id} 没有任何instance"
        return []
      end

      Rails.logger.info "[MerkleTreeGenerator] item_id=#{item_id} 总计有 #{total_count} 个instance"

      # 分批获取所有 token_id（使用 id 列）
      batch_size = get_optimal_batch_size(total_count)
      all_tokens = []
      processed_count = 0

      Rails.logger.info "[MerkleTreeGenerator] 开始分批获取，批次大小=#{batch_size}"

      instances.select(:id)
              .find_in_batches(batch_size: batch_size) do |batch|
        batch_tokens = batch.map(&:id).map(&:to_s)
        all_tokens.concat(batch_tokens)
        processed_count += batch_tokens.length
        Rails.logger.debug "[MerkleTreeGenerator] 已处理 #{processed_count}/#{total_count} 个instance"
      end

      # 去重检查
      unique_tokens = all_tokens.uniq
      if unique_tokens.length != all_tokens.length
        duplicates_count = all_tokens.length - unique_tokens.length
        Rails.logger.warn "[MerkleTreeGenerator] 发现并移除了 #{duplicates_count} 个重复token"
        all_tokens = unique_tokens
      end

      if all_tokens.length == 0
        Rails.logger.error "[MerkleTreeGenerator] 去重后没有有效的token"
        raise "没有获取到有效的token数据"
      end

      # 验证token格式
      invalid_tokens = all_tokens.select { |token| !valid_token_format?(token) }
      if invalid_tokens.any?
        Rails.logger.error "[MerkleTreeGenerator] 发现 #{invalid_tokens.length} 个无效格式的token"
        raise "发现无效格式的token，请检查数据质量"
      end

      Rails.logger.info "[MerkleTreeGenerator] ✓ 成功获取 item_id=#{item_id} 的 #{all_tokens.length} 个token"
      all_tokens

    rescue => e
      Rails.logger.error "[MerkleTreeGenerator] 获取token列表失败: #{e.message}"
      Rails.logger.error e.backtrace.first(5).join("\n")
      raise e
    end
    
    # 根据数据量确定最优批次大小
    def self.get_optimal_batch_size(total_count)
      max_batch_size = Rails.configuration.x.merkle_tree.batch_size_limit
      
      case total_count
      when 0..1000
        [500, max_batch_size].min    # 小数据集，较大批次
      when 1001..10000
        [1000, max_batch_size].min   # 中等数据集
      when 10001..100000
        [2000, max_batch_size].min   # 大数据集，平衡内存和IO
      else
        [3000, max_batch_size].min   # 超大数据集，不超过配置限制
      end
    end
    
    # 验证token格式是否有效
    def self.valid_token_format?(token)
      return false if token.blank?
      
      # 检查是否为有效的数字字符串
      return false unless token.to_s.match?(/^\d+$/)
      
      # 检查是否为正数
      return false unless token.to_i > 0
      
      # 检查长度是否合理（最少5位，过滤掉 item_id）
      token_str = token.to_s
      return false if token_str.length < 5 || token_str.length > 100
      
      true
    end
    
    # 获取所有需要生成Merkle树的NFT集合item_id列表
    def self.get_nft_collection_item_ids
      # 从Market表获取可交易的item_id
      market_items = Trading::Market.distinct.pluck(:item_id).compact

      # 从索引器表获取所有item_id，过滤出有instance的
      nft_collections = []

      market_items.each do |item_id|
        begin
          instance_count = ItemIndexer::Instance.where(item: item_id).count

          # 只要有 instance 就生成 Merkle 树（统一处理 NFT 和同质代币）
          nft_collections << item_id
          Rails.logger.debug "[MerkleTreeGenerator] ✓ item_id=#{item_id} 需要生成Merkle树 (#{instance_count}个instance)"

        rescue => e
          Rails.logger.warn "[MerkleTreeGenerator] 检查 item_id=#{item_id} 时出错: #{e.message}"
        end
      end

      Rails.logger.info "[MerkleTreeGenerator] 找到 #{nft_collections.length} 个NFT集合需要生成Merkle树"
      nft_collections
    end

    # 验证token格式的有效性
    def self.validate_tokens(tokens)
      tokens.each do |token|
        # 验证token是否为有效的数字字符串
        unless token.to_s.match?(/^\d+$/)
          raise "无效的token格式: #{token}"
        end
        
        # 验证token是否为正数
        if token.to_i <= 0
          raise "token必须为正数: #{token}"
        end
      end
      
      # 验证token是否有重复
      if tokens.length != tokens.uniq.length
        duplicates = tokens.group_by(&:to_s).select { |_, v| v.length > 1 }.keys
        raise "发现重复的token: #{duplicates.join(', ')}"
      end
    end
  end
end
