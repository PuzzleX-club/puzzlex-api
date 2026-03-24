# frozen_string_literal: true

namespace :catalog_data do
  def catalog_provider
    Metadata::Catalog::ProviderRegistry.current
  end

  def repo_sync_fetcher
    Metadata::Catalog::Providers::RepoSync::Fetcher
  end

  desc '从 GitHub 同步所有 CatalogData 数据（物品和配方）'
  task sync_all: :environment do
    puts "[CatalogData] 开始从 GitHub 同步所有数据..."
    start_time = Time.current

    results = catalog_provider.sync_all

    duration = Time.current - start_time
    puts "\n[CatalogData] ===== 同步完成 ====="
    puts "耗时: #{duration.round(2)} 秒"
    puts "\n统计结果:"

    results.each do |type, stats|
      if stats[:error]
        puts "  #{type}: 错误 - #{stats[:error]}"
      else
        puts "  #{type}:"
        puts "    新增: #{stats[:created] || 0}"
        puts "    更新: #{stats[:updated] || 0}"
        puts "    未变: #{stats[:unchanged] || 0}"
        if stats[:translations]
          puts "    翻译新增: #{stats[:translations][:created] || 0}"
          puts "    翻译更新: #{stats[:translations][:updated] || 0}"
        end
      end
    end
  end

  desc '从 GitHub 同步物品数据'
  task sync_items: :environment do
    puts "[CatalogData] 开始同步物品数据..."
    stats = catalog_provider.sync_items

    if stats[:error]
      puts "同步失败: #{stats[:error]}"
    else
      puts "物品同步完成:"
      puts "  新增: #{stats[:created]}"
      puts "  更新: #{stats[:updated]}"
      puts "  未变: #{stats[:unchanged]}"
      puts "  翻译新增: #{stats[:translations][:created]}"
      puts "  翻译更新: #{stats[:translations][:updated]}"
    end
  end

  desc '从 GitHub 同步配方数据'
  task sync_recipes: :environment do
    puts "[CatalogData] 开始同步配方数据..."
    stats = catalog_provider.sync_recipes

    if stats[:error]
      puts "同步失败: #{stats[:error]}"
    else
      puts "配方同步完成:"
      puts "  新增: #{stats[:created]}"
      puts "  更新: #{stats[:updated]}"
      puts "  未变: #{stats[:unchanged]}"
      puts "  翻译新增: #{stats[:translations][:created]}"
      puts "  翻译更新: #{stats[:translations][:updated]}"
    end
  end

  desc '从本地文件导入物品数据'
  task :import_items, [:file_path, :locale] => :environment do |t, args|
    file_path = args[:file_path] || '/Users/leo/Downloads/Item-25_副本.csv'
    locale = args[:locale] || 'zh-CN'

    puts "[CatalogData] 从本地文件导入物品数据: #{file_path} (#{locale})"

    unless File.exist?(file_path)
      puts "错误: 文件不存在 #{file_path}"
      exit 1
    end

    stats = catalog_provider.sync_from_local_file(file_path, 'Item', locale)

    if stats[:error]
      puts "导入失败: #{stats[:error]}"
    else
      puts "物品导入完成:"
      puts "  新增: #{stats[:created]}"
      puts "  更新: #{stats[:updated]}"
      puts "  未变: #{stats[:unchanged]}"
      puts "  翻译新增: #{stats[:translations][:created]}"
      puts "  翻译更新: #{stats[:translations][:updated]}"
    end
  end

  desc '从本地文件导入配方数据'
  task :import_recipes, [:file_path, :locale] => :environment do |t, args|
    file_path = args[:file_path] || '/Users/leo/Downloads/Recipes.csv'
    locale = args[:locale] || 'zh-CN'

    puts "[CatalogData] 从本地文件导入配方数据: #{file_path} (#{locale})"

    unless File.exist?(file_path)
      puts "错误: 文件不存在 #{file_path}"
      exit 1
    end

    stats = catalog_provider.sync_from_local_file(file_path, 'Recipes', locale)

    if stats[:error]
      puts "导入失败: #{stats[:error]}"
    else
      puts "配方导入完成:"
      puts "  新增: #{stats[:created]}"
      puts "  更新: #{stats[:updated]}"
      puts "  未变: #{stats[:unchanged]}"
      puts "  翻译新增: #{stats[:translations][:created]}"
      puts "  翻译更新: #{stats[:translations][:updated]}"
    end
  end

  desc '显示统计信息'
  task stats: :environment do
    puts "[CatalogData] 数据库统计信息"
    puts "=" * 50

    # 物品统计
    item_count = CatalogData::Item.count
    item_translation_count = CatalogData::ItemTranslation.count

    puts "物品:"
    puts "  总数: #{item_count}"
    puts "  可铸造: #{CatalogData::Item.mintable.count}"
    puts "  可出售: #{CatalogData::Item.sellable.count}"
    puts "  翻译总数: #{item_translation_count}"

    # 按语言统计
    CatalogData::ItemTranslation.group(:locale).count.each do |locale, count|
      puts "    #{locale}: #{count}"
    end

    # 配方统计
    recipe_count = CatalogData::Recipe.count
    recipe_translation_count = CatalogData::RecipeTranslation.count

    puts "\n配方:"
    puts "  总数: #{recipe_count}"
    puts "  启用: #{CatalogData::Recipe.enabled.count}"
    puts "  翻译总数: #{recipe_translation_count}"

    # 按语言统计
    CatalogData::RecipeTranslation.group(:locale).count.each do |locale, count|
      puts "    #{locale}: #{count}"
    end

    puts "=" * 50
  end

  desc '测试 GitHub 连接'
  task test_github: :environment do
    puts "[CatalogData] 测试 GitHub 连接..."

    begin
      # 测试下载物品文件
      hash = repo_sync_fetcher.fetch_file_hash('Item', 'zh-CN')
      puts "✓ 物品文件 (zh-CN) 下载成功，hash: #{hash[0..15]}..."

      # 测试下载配方文件
      hash = repo_sync_fetcher.fetch_file_hash('Recipes', 'zh-CN')
      puts "✓ 配方文件 (zh-CN) 下载成功，hash: #{hash[0..15]}..."

      # 测试英文版本
      hash = repo_sync_fetcher.fetch_file_hash('Item', 'en')
      puts "✓ 物品文件 (en) 下载成功，hash: #{hash[0..15]}..."

      puts "\nGitHub 连接测试成功！"
    rescue => e
      puts "\nGitHub 连接测试失败: #{e.message}"
      exit 1
    end
  end

  desc '清理测试数据（仅限测试环境）'
  task cleanup: :environment do
    unless Rails.env.test? || Rails.env.development?
      puts "错误: 此任务只能在测试或开发环境运行"
      exit 1
    end

    puts "[CatalogData] 清理测试数据..."

    CatalogData::RecipeProduct.delete_all
    CatalogData::RecipeMaterial.delete_all
    CatalogData::RecipeTranslation.delete_all
    CatalogData::Recipe.delete_all
    CatalogData::ItemTranslation.delete_all
    CatalogData::Item.delete_all

    puts "✓ 测试数据已清理"
  end
end
