# frozen_string_literal: true

namespace :item_indexer do
  ZERO_ADDRESS = '0x0000000000000000000000000000000000000000'

  desc '备份 Item/Instance 表（维护窗口用）'
  task backup: :environment do
    timestamp = Time.now.strftime('%Y%m%d_%H%M%S')
    filename = "/tmp/item_indexer_backup_#{timestamp}.sql"

    puts "=== 备份 Item/Instance 表 ==="
    puts "  输出文件: #{filename}"

    # 直接用 Rails 的数据库连接配置
    db_config = ActiveRecord::Base.connection_db_config.configuration_hash
    db_name = db_config[:database]
    db_host = db_config[:host] || 'localhost'
    db_user = db_config[:username]

    tables = %w[item_indexer_items item_indexer_instances]
    table_opts = tables.map { |t| "-t #{t}" }.join(' ')

    # 使用 PGPASSWORD 环境变量传递密码
    cmd = "PGPASSWORD='#{db_config[:password]}' pg_dump -h #{db_host} -U #{db_user} #{table_opts} #{db_name} > #{filename}"

    if system(cmd)
      puts "  ✅ 备份完成: #{filename}"
      puts "  文件大小: #{File.size(filename) / 1024}KB"
    else
      puts "  ❌ 备份失败"
      exit 1
    end
  end

  desc '清零 Item/Instance 统计字段'
  task reset_stats: :environment do
    puts "=== 清零统计字段 ==="

    puts "  清零 Item..."
    item_count = ItemIndexer::Item.update_all(
      minted_amount: 0, burned_amount: 0, total_supply: 0
    )
    puts "    ✅ #{item_count} 个 Item 已清零"

    puts "  清零 Instance..."
    instance_count = ItemIndexer::Instance.update_all(
      minted_amount: 0, burned_amount: 0, total_supply: 0
    )
    puts "    ✅ #{instance_count} 个 Instance 已清零"
  end

  desc '全量重算统计（维护窗口用，需先停 Sidekiq）'
  task recalculate_all: :environment do
    puts "=== 全量重算统计 ==="
    total_start = Time.now

    # 阶段1：Item（纯 SQL）
    recalculate_items

    # 阶段2：Instance（纯 SQL）
    recalculate_instances

    puts ''
    puts "=== 全部完成! 总耗时: #{(Time.now - total_start).round(1)}s ==="
  end

  desc '重算所有 Item 和 Instance 的统计数据 (修复负数余额问题)'
  task recalculate_stats: :environment do
    puts '开始重算统计数据...'
    puts '警告: 这将清零并重新计算所有 Item/Instance 的 minted/burned/total_supply'
    puts '按 Ctrl+C 取消，或等待 5 秒继续...'

    begin
      sleep 5
    rescue Interrupt
      puts '已取消'
      exit 0
    end

    Indexer::StatsRecalculator.new.recalculate_all
    puts '完成!'
  end

  desc '重算指定 Item 的统计数据'
  task :recalculate_item, [:item_id] => :environment do |_t, args|
    item_id = args[:item_id]

    if item_id.blank?
      puts '用法: rake item_indexer:recalculate_item[ITEM_ID]'
      puts '示例: rake item_indexer:recalculate_item[1139]'
      exit 1
    end

    Indexer::StatsRecalculator.new.recalculate_item(item_id)
  end

  desc '验证单个 Item 统计数据'
  task :verify_item, [:item_id] => :environment do |_t, args|
    item_id = args[:item_id]

    if item_id.blank?
      puts '用法: rake item_indexer:verify_item[ITEM_ID]'
      puts '示例: rake item_indexer:verify_item[1139]'
      exit 1
    end

    verify_item_stats(item_id)
  end

  desc '随机抽样验证 N 个 Item'
  task :verify_random, [:count] => :environment do |_t, args|
    count = (args[:count] || 5).to_i
    puts "=== 随机抽样验证 #{count} 个 Item ==="

    ItemIndexer::Item.order('RANDOM()').limit(count).each do |item|
      verify_item_stats(item.id)
    end
  end

  # === 私有方法（定义在 rake 命名空间内） ===

  def recalculate_items
    puts ''
    puts '--- 阶段1: 重算 Item 统计（纯 SQL）---'
    start = Time.now

    sql = <<-SQL
      UPDATE item_indexer_items AS i SET
        minted_amount = COALESCE(s.minted, 0),
        burned_amount = COALESCE(s.burned, 0),
        total_supply = COALESCE(s.minted, 0) - COALESCE(s.burned, 0)
      FROM (
        SELECT item,
          SUM(CASE WHEN from_address = '#{ZERO_ADDRESS}' THEN amount ELSE 0 END) AS minted,
          SUM(CASE WHEN to_address = '#{ZERO_ADDRESS}' THEN amount ELSE 0 END) AS burned
        FROM item_indexer_transactions
        GROUP BY item
      ) AS s
      WHERE i.id = s.item
    SQL

    result = ActiveRecord::Base.connection.execute(sql)
    puts "  ✅ 更新了 #{result.cmd_tuples} 个 Item (#{(Time.now - start).round(1)}s)"
  end

  def recalculate_instances
    puts ''
    puts '--- 阶段2: 重算 Instance 统计（纯 SQL）---'
    start = Time.now

    # Instance 也使用纯 SQL UPDATE，性能最优，无需分页
    sql = <<-SQL
      UPDATE item_indexer_instances AS inst SET
        minted_amount = COALESCE(s.minted, 0),
        burned_amount = COALESCE(s.burned, 0),
        total_supply = COALESCE(s.minted, 0) - COALESCE(s.burned, 0)
      FROM (
        SELECT instance,
          SUM(CASE WHEN from_address = '#{ZERO_ADDRESS}' THEN amount ELSE 0 END) AS minted,
          SUM(CASE WHEN to_address = '#{ZERO_ADDRESS}' THEN amount ELSE 0 END) AS burned
        FROM item_indexer_transactions
        GROUP BY instance
      ) AS s
      WHERE inst.id = s.instance
    SQL

    result = ActiveRecord::Base.connection.execute(sql)
    puts "  ✅ 更新了 #{result.cmd_tuples} 个 Instance (#{(Time.now - start).round(1)}s)"
  end

  def verify_item_stats(item_id)
    item = ItemIndexer::Item.find_by(id: item_id)
    unless item
      puts "❌ Item #{item_id} 不存在"
      return
    end

    # 从 Transaction 重算
    txs = ItemIndexer::Transaction.where(item: item_id)
    minted = txs.where(from_address: ZERO_ADDRESS).sum(:amount)
    burned = txs.where(to_address: ZERO_ADDRESS).sum(:amount)

    match = (item.minted_amount == minted && item.burned_amount == burned)
    status = match ? '✅' : '❌'
    puts "#{status} Item #{item_id}: DB(minted=#{item.minted_amount}, burned=#{item.burned_amount}) vs TX(minted=#{minted}, burned=#{burned})"
  end
end
