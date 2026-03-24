namespace :merkle_tree do
  desc "显示Merkle树状态统计"
  task status: :environment do
    puts "=== Merkle树状态统计 ==="
    
    # 总体统计
    total_nodes = Merkle::TreeNode.count
    total_snapshots = Merkle::TreeNode.select(:snapshot_id).distinct.count
    root_stats = Merkle::TreeRoot.statistics
    
    puts "总节点数: #{total_nodes}"
    puts "总快照数: #{total_snapshots}"
    puts "根节点记录总数: #{root_stats[:total_roots]}"
    puts "活跃根节点数: #{root_stats[:active_roots]}"
    puts "已删除根节点数: #{root_stats[:deleted_roots]}"
    puts "涉及物品数: #{root_stats[:items_with_roots]}"
    
    if root_stats[:oldest_active]
      oldest_age = ((Time.current - root_stats[:oldest_active]) / 1.day).round(1)
      puts "最旧活跃根节点: #{oldest_age}天前"
    end
    
    if root_stats[:newest_root]
      newest_age = ((Time.current - root_stats[:newest_root]) / 1.hour).round(1)
      puts "最新根节点: #{newest_age}小时前"
    end
    
    # 按item_id统计根节点
    puts "\n=== 各物品的根节点统计 ==="
    
    active_items = Merkle::TreeRoot.active
                                          .group(:item_id)
                                          .maximum(:created_at)
    
    active_items.each do |item_id, latest_time|
      total_roots = Merkle::TreeRoot.where(item_id: item_id).count
      active_roots = Merkle::TreeRoot.where(item_id: item_id, tree_exists: true).count
      age_hours = ((Time.current - latest_time) / 1.hour).round(1)
      
      puts "Item #{item_id}: #{active_roots}/#{total_roots}个根节点(活跃/总计), 最新: #{age_hours}小时前"
    end
    
    # 存储使用情况
    puts "\n=== 存储使用情况 ==="
    old_nodes = Merkle::TreeNode.where('created_at < ?', 10.days.ago).count
    puts "超过10天的节点: #{old_nodes} (可清理)"
    
    size_estimate = total_nodes * 0.2 # 假设每个节点约200字节
    puts "估计存储大小: #{(size_estimate / 1024 / 1024).round(2)} MB"
  end

  desc "手动生成指定item_id的Merkle树"
  task :generate, [:item_id] => :environment do |t, args|
    item_id = args[:item_id]
    
    if item_id.blank?
      puts "用法: rake merkle_tree:generate[43]"
      exit 1
    end
    
    puts "正在为 item_id=#{item_id} 生成Merkle树..."
    
    begin
      result = Merkle::TreeGenerator.generate_and_persist(item_id)
      puts "✓ 生成成功:"
      puts "  snapshot_id: #{result[:snapshot_id]}"
      puts "  merkle_root: #{result[:merkle_root]}"
      puts "  token_count: #{result[:token_count]}"
    rescue => e
      puts "❌ 生成失败: #{e.message}"
      exit 1
    end
  end

  desc "清理过期的Merkle树数据"
  task cleanup: :environment do
    puts "开始清理超过10天的Merkle树数据..."
    
    cutoff_time = 10.days.ago
    old_snapshots = Merkle::TreeNode.where('created_at < ?', cutoff_time)
                                           .select(:snapshot_id)
                                           .distinct
                                           .pluck(:snapshot_id)
    
    if old_snapshots.empty?
      puts "没有需要清理的数据"
      return
    end
    
    puts "发现 #{old_snapshots.length} 个过期快照"
    
    # 先标记根节点记录为已删除
    Merkle::TreeRoot.mark_trees_as_deleted(old_snapshots)
    puts "✓ 已标记 #{old_snapshots.length} 个根节点为已删除状态"
    
    deleted_count = 0
    old_snapshots.each do |snapshot_id|
      nodes_count = Merkle::TreeNode.where(snapshot_id: snapshot_id).count
      Merkle::TreeNode.where(snapshot_id: snapshot_id).delete_all
      deleted_count += nodes_count
      puts "删除快照 #{snapshot_id} (#{nodes_count} 个节点)"
    end
    
    puts "✓ 清理完成，删除了 #{deleted_count} 个节点，保留了根节点历史记录"
  end

  desc "验证Merkle树数据完整性"
  task verify: :environment do
    puts "验证Merkle树数据完整性..."
    
    issues = []
    
    # 检查是否有孤儿节点
    snapshots_with_nodes = Merkle::TreeNode.select(:snapshot_id).distinct.pluck(:snapshot_id)
    snapshots_with_roots = Merkle::TreeRoot.pluck(:snapshot_id)
    
    orphan_snapshots = snapshots_with_nodes - snapshots_with_roots
    if orphan_snapshots.any?
      issues << "发现 #{orphan_snapshots.length} 个没有根节点记录的快照: #{orphan_snapshots.first(3).join(', ')}"
    end
    
    # 检查根节点记录与实际树数据的一致性
    inconsistent_roots = []
    Merkle::TreeRoot.where(tree_exists: true).find_each do |root|
      actual_nodes = Merkle::TreeNode.where(snapshot_id: root.snapshot_id).exists?
      unless actual_nodes
        inconsistent_roots << root.snapshot_id
      end
    end
    
    if inconsistent_roots.any?
      issues << "发现 #{inconsistent_roots.length} 个标记为存在但实际数据已删除的根节点"
    end
    
    # 检查是否有重复的根节点hash
    duplicate_hashes = Merkle::TreeRoot.group(:root_hash)
                                              .having('COUNT(*) > 1')
                                              .count
    if duplicate_hashes.any?
      issues << "发现 #{duplicate_hashes.length} 个重复的根节点hash"
    end
    
    if issues.empty?
      puts "✓ 数据完整性验证通过"
    else
      puts "❌ 发现以下问题:"
      issues.each { |issue| puts "  - #{issue}" }
    end
  end

  desc "显示指定item_id的根节点信息"
  task :roots, [:item_id] => :environment do |t, args|
    item_id = args[:item_id]
    
    if item_id.blank?
      puts "用法: rake merkle_tree:roots[43]"
      exit 1
    end
    
    puts "Item #{item_id} 的根节点信息:"
    
    roots = Merkle::TreeRoot.all_roots_for_item(item_id, 20)
    
    if roots.empty?
      puts "没有找到任何根节点"
      return
    end
    
    roots.each_with_index do |root, index|
      status_icon = root[:tree_exists] ? "✓" : "✗"
      age_info = "#{root[:age_hours]}小时前"
      token_info = "#{root[:token_count]}个token"
      
      puts "#{index + 1}. #{status_icon} #{root[:root_hash][0..10]}... (#{age_info}, #{token_info}) [#{root[:status]}]"
    end
  end
  
  desc "检查指定根节点的状态"
  task :check_root, [:root_hash] => :environment do |t, args|
    root_hash = args[:root_hash]
    
    if root_hash.blank?
      puts "用法: rake merkle_tree:check_root[0x...]"
      exit 1
    end
    
    puts "检查根节点状态: #{root_hash}"
    
    status = Merkle::TreeRoot.check_root_status(root_hash)
    
    puts "状态: #{status[:status]}"
    puts "信息: #{status[:message]}"
    
    if status[:exists]
      puts "详细信息:"
      puts "  item_id: #{status[:item_id]}"
      puts "  token数量: #{status[:token_count]}"
      puts "  创建时间: #{status[:created_at]}"
      puts "  年龄: #{status[:age_days]}天"
      puts "  树是否存在: #{status[:tree_exists]}"
      puts "  删除时间: #{status[:tree_deleted_at]}" if status[:tree_deleted_at]
    end
  end

  desc "测试数据获取功能"
  task :test_data_fetch, [:item_id] => :environment do |t, args|
    item_id = args[:item_id]
    
    if item_id.blank?
      puts "用法: rake merkle_tree:test_data_fetch[43]"
      exit 1
    end
    
    puts "测试 item_id=#{item_id} 的数据获取..."
    
    begin
      start_time = Time.current
      
      # 测试数据获取
      tokens = Merkle::TreeGenerator.send(:get_tokens_for_item, item_id)
      
      duration = Time.current - start_time
      
      puts "✓ 数据获取成功："
      puts "  token数量: #{tokens.length}"
      puts "  获取耗时: #{duration.round(2)}秒"
      puts "  前5个token: #{tokens.first(5)}"
      puts "  后5个token: #{tokens.last(5)}" if tokens.length > 5
      
      # 检查数据质量
      invalid_count = 0
      tokens.each do |token|
        unless Merkle::TreeGenerator.send(:valid_token_format?, token)
          invalid_count += 1
        end
      end
      
      if invalid_count > 0
        puts "⚠️  发现 #{invalid_count} 个无效格式的token"
      else
        puts "✓ 所有token格式验证通过"
      end
      
      # 估算内存使用
      memory_mb = (tokens.size * 50) / 1024 / 1024
      puts "  估算内存使用: #{memory_mb} MB"
      
    rescue => e
      puts "❌ 数据获取失败: #{e.message}"
      puts "错误堆栈:"
      puts e.backtrace.first(5)
    end
  end
  
  desc "列出所有NFT集合"
  task list_nft_collections: :environment do
    puts "扫描所有NFT集合..."
    
    begin
      collections = Merkle::TreeGenerator.send(:get_nft_collection_item_ids)
      
      puts "\n找到 #{collections.length} 个NFT集合:"
      puts "=" * 80
      
      collections.each_with_index do |item_id, index|
        begin
          item = Item.find_by(itemId: item_id)
          if item
            instance_count = Instance.where(product_id: item.product_id).count
            classification = item.classification
            
            # 判断NFT类型
            reasons = []
            reasons << "#{instance_count}个instance" if instance_count > 1
            reasons << "装备类物品" if classification == "装备"
            
            nft_type = reasons.join(" + ")
            item_name = item.name_cn || item.name_en || "未知名称"
            
            puts "#{index + 1}. item_id=#{item_id} (#{item_name}) - #{nft_type} [分类: #{classification}]"
          else
            puts "#{index + 1}. item_id=#{item_id} (未找到物品信息)"
          end
        rescue => e
          puts "#{index + 1}. item_id=#{item_id} (查询出错: #{e.message})"
        end
      end
      
      if collections.empty?
        puts "没有找到任何NFT集合。"
        puts "请检查："
        puts "1. Market表中是否有数据"
        puts "2. Item表和Instance表的关联是否正确"
        puts "3. 是否有物品满足NFT条件："
        puts "   - 拥有多个instance (传统NFT集合)"
        puts "   - 或者分类为'装备' (装备类NFT)"
      else
        puts "\n" + "=" * 80
        puts "NFT判断规则："
        puts "✓ 多个instance (instance_count > 1) - 传统NFT集合"
        puts "✓ 装备分类 (classification == '装备') - 装备类NFT"
        puts "注：满足任一条件即为NFT集合，需要生成Merkle树"
      end
      
    rescue => e
      puts "❌ 扫描失败: #{e.message}"
    end
  end
end 