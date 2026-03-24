# frozen_string_literal: true

namespace :catalog_data do
  desc "清理 catalog 表下的所有数据"
  task clear: :environment do
    puts "⚠️  警告：即将清理 catalog 表下的所有数据！"
    puts "包含的表："
    puts "  - catalog_items"
    puts "  - catalog_item_translations"
    puts "  - catalog_recipes"
    puts "  - catalog_recipe_translations"
    puts "  - catalog_recipe_materials"
    puts "  - catalog_recipe_products"
    puts

    print "确认继续吗？(输入 'yes' 继续): "
    confirmation = STDIN.gets.chomp.strip.downcase

    unless confirmation == 'yes'
      puts "❌ 操作已取消"
      exit 0
    end

    puts "\n开始清理 catalog 数据..."

    begin
      ActiveRecord::Base.connection.execute("SET session_replication_role = replica")

      tables = %w[
        catalog_item_translations
        catalog_recipe_materials
        catalog_recipe_products
        catalog_recipe_translations
        catalog_recipes
        catalog_items
      ]

      puts "\n清理前的数据量："
      tables.each do |table|
        count = ActiveRecord::Base.connection.execute(
          "SELECT COUNT(*) FROM #{table}"
        ).first['count']
        puts "  #{table}: #{count} 条记录"
      end

      puts "\n执行 TRUNCATE 操作..."
      tables.each do |table|
        ActiveRecord::Base.connection.execute("TRUNCATE TABLE #{table} CASCADE")
        puts "  ✅ 清理完成: #{table}"
      end

      ActiveRecord::Base.connection.execute("SET session_replication_role = DEFAULT")

      puts "\n清理后的数据量："
      tables.each do |table|
        count = ActiveRecord::Base.connection.execute(
          "SELECT COUNT(*) FROM #{table}"
        ).first['count']
        puts "  #{table}: #{count} 条记录"
      end

      puts "\n✅ Catalog 数据清理完成！"
    rescue => e
      puts "\n❌ 清理过程中出现错误："
      puts e.message
      puts e.backtrace.join("\n")

      begin
        ActiveRecord::Base.connection.execute("SET session_replication_role = DEFAULT")
      rescue
      end

      exit 1
    end
  end

  desc "检查 catalog 表的状态"
  task status: :environment do
    puts "Catalog 表状态："
    puts "=" * 50

    tables = %w[
      catalog_items
      catalog_item_translations
      catalog_recipes
      catalog_recipe_translations
      catalog_recipe_materials
      catalog_recipe_products
    ]

    total_records = 0

    tables.each do |table|
      begin
        result = ActiveRecord::Base.connection.execute(
          "SELECT COUNT(*) as count FROM #{table}"
        ).first

        count = result['count']
        total_records += count.to_i

        printf "%-30s: %8d 条记录\n", table, count
      rescue => e
        printf "%-30s: %s\n", table, "错误 - #{e.message}"
      end
    end

    puts "=" * 50
    printf "%-30s: %8d 条记录\n", "总计", total_records
  end
end
