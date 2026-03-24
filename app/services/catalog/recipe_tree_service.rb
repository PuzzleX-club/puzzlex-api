# frozen_string_literal: true

# 配方树服务
# =====================================
# 递归计算物品的完整生产配方树，直到基础材料
#
# 使用示例:
#   Catalog::RecipeTreeService.new(item_id).calculate
#
# 返回格式:
#   {
#     item_id: 123,
#     item_name: "高级武器",
#     recipes: [...],        # 该物品的所有配方
#     is_base_material: false # 是否是基础材料（无配方）
#   }
#
module Catalog
  class RecipeTreeService
    MAX_DEPTH = 20 # 最大递归深度，防止循环依赖
    RecipesDisabledError = Class.new(StandardError)

    def initialize(item_id, locale: 'zh-CN', depth: 0)
      @item_id = item_id
      @locale = locale
      @depth = depth
      @visited_items = Set.new # 追踪已访问的 item，防止循环
    end

    def calculate
      # Check recipes capability only at the top-level entry (depth 0).
      # Child instances (depth > 0) inherit the parent's capability decision.
      if @depth == 0 && !Metadata::Catalog::ProviderRegistry.current.capabilities[:recipes]
        raise RecipesDisabledError, 'Recipes feature is not available for this project'
      end

      # 防止无限递归
      if @depth >= MAX_DEPTH
        Rails.logger.warn "[Catalog::RecipeTreeService] 达到最大递归深度 depth=#{@depth}, item_id=#{@item_id}"
        return base_material_node
      end

      # 防止循环依赖
      if @visited_items.include?(@item_id)
        Rails.logger.warn "[Catalog::RecipeTreeService] 检测到循环依赖 item_id=#{@item_id}"
        return base_material_node
      end

      @visited_items.add(@item_id)

      # 获取物品信息
      item_info = fetch_item_info(@item_id)

      # 查找该物品的所有配方（作为产出物）
      recipes = find_recipes_by_product(@item_id)

      if recipes.empty?
        # 无配方 = 基础材料
        {
          item_id: @item_id,
          item_name: item_info[:name],
          item_info: item_info,
          recipes: [],
          is_base_material: true
        }
      else
        # 有配方，递归计算每个配方的材料树
        recipes_data = recipes.map { |recipe| build_recipe_node(recipe) }

        {
          item_id: @item_id,
          item_name: item_info[:name],
          item_info: item_info,
          recipes: recipes_data,
          is_base_material: false
        }
      end
    end

    private

    # 构建基础材料节点
    def base_material_node
      item_info = fetch_item_info(@item_id)
      {
        item_id: @item_id,
        item_name: item_info[:name],
        item_info: item_info,
        recipes: [],
        is_base_material: true
      }
    end

    # 查找能产出该物品的所有配方
    def find_recipes_by_product(item_id)
      catalog_provider.find_recipes_by_product(item_id)
    end

    # 构建配方节点
    def build_recipe_node(recipe)
      # 获取配方翻译
      translation = recipe.translations.find { |t| t.locale == @locale } ||
                    recipe.translations.find { |t| t.locale == 'zh-CN' } ||
                    recipe.translations.first

      # 计算产物概率（基于 weight）
      products = calculate_products(recipe)

      # 递归计算材料树
      materials = calculate_materials(recipe)

      {
        recipe_id: recipe.recipe_id,
        recipe_name: translation&.name || "Recipe##{recipe.recipe_id}",
        description: translation&.description,
        enabled: recipe.enabled,
        products: products,
        materials: materials
      }
    end

    # 计算产物信息（带概率）
    def calculate_products(recipe)
      products = Array(catalog_provider.recipe_products(recipe)).map do |product|
        {
          item_id: product.item_id,
          weight: product.weight || 1,
          min_quantity: product.quantity || 1,  # RecipeProduct表没有min/max_quantity字段
          max_quantity: product.quantity || 1
        }
      end

      # 计算概率：probability = weight / sum(weights)
      total_weight = products.sum { |p| p[:weight] }

      products.each do |product|
        product[:probability] = total_weight > 0 ? product[:weight].to_f / total_weight : 0

        # 添加物品信息
        product[:item_info] = fetch_item_info(product[:item_id])
      end

      products
    end

    # 递归计算材料树
    def calculate_materials(recipe)
      Array(catalog_provider.recipe_materials(recipe)).map do |material|
        # 递归查找材料的配方树
        sub_tree_service = self.class.new(
          material.item_id,
          locale: @locale,
          depth: @depth + 1
        )
        sub_tree_service.instance_variable_set(:@visited_items, @visited_items.dup)
        sub_tree = sub_tree_service.calculate

        {
          item_id: material.item_id,
          quantity: material.quantity,
          allow_substitute: false,  # RecipeMaterial表没有allow_substitute字段
          item_info: fetch_item_info(material.item_id),
          sub_tree: sub_tree
        }
      end
    end

    # 获取物品信息（带缓存）
    def fetch_item_info(item_id)
      cache_key = "recipe_tree:item_info:#{catalog_provider.provider_key}:#{item_id}:#{@locale}"

      Rails.cache.fetch(cache_key, expires_in: 1.hour) do
        item = catalog_provider.find_item(item_id)

        if item.nil?
          {
            item_id: item_id,
            name: "Unknown Item##{item_id}",
            description: nil,
            image_url: nil
          }
        else
          translations = Array(item.translations)
          translation = translations.find { |t| t.locale == @locale } ||
                        translations.find { |t| t.locale == 'zh-CN' } ||
                        translations.first

          {
            item_id: item.item_id,
            name: translation&.name || "Item##{item.item_id}",
            description: translation&.description,
            image_url: parse_icon_array(item.icon).first,
            item_type: item.item_type,
            quality: item.extra('quality', [])
          }
        end
      end
    rescue StandardError => e
      Rails.logger.error "[Catalog::RecipeTreeService] 获取物品信息失败 item_id=#{item_id}: #{e.message}"
      {
        item_id: item_id,
        name: "Error Item##{item_id}",
        description: nil,
        image_url: nil
      }
    end

    def catalog_provider
      @catalog_provider ||= Metadata::Catalog::ProviderRegistry.current
    end

    # 解析 icon 字段（复制自 BaseController）
    def parse_icon_array(icon_field)
      return [] if icon_field.blank?

      if icon_field.is_a?(String)
        trimmed = icon_field.strip
        if trimmed.start_with?('{', '[')
          parsed = JSON.parse(trimmed) rescue nil
          if parsed
            if parsed.is_a?(Hash)
              url = parsed['url'] || parsed['image']
              return url ? [url] : []
            end
            return Array(parsed)
          end
        end
        [trimmed]
      elsif icon_field.is_a?(Array)
        icon_field.compact
      else
        Array(icon_field)
      end
    rescue StandardError
      Array(icon_field)
    end
  end
end
