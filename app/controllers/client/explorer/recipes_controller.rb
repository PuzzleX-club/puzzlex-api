# frozen_string_literal: true

module Client
  module Explorer
    # 配方查询API
    # =====================================
    # 提供配方列表、详情、递归配方树查询
    #
    class RecipesController < BaseController
      before_action :require_recipes_capability

      # GET /api/explorer/recipes
      # 获取配方列表（支持按产出物品筛选、名称搜索）
      def index
        recipes = catalog_provider.list_recipes(
          keyword: params[:keyword],
          item_id: params[:item_id],
          item_ids: parsed_item_ids_filter
        )

        page_params = pagination_params
        total_count = recipes.size
        offset = (page_params[:page] - 1) * page_params[:per_page]
        paged_recipes = recipes.slice(offset, page_params[:per_page]) || []

        products_by_recipe = {}
        materials_by_recipe = {}
        translations_by_recipe = {}
        paged_recipes.each do |recipe|
          products_by_recipe[recipe.recipe_id] = Array(catalog_provider.recipe_products(recipe))
          materials_by_recipe[recipe.recipe_id] = Array(catalog_provider.recipe_materials(recipe))
          translations_by_recipe[recipe.recipe_id] = Array(recipe.translations)
        end

        # 组装响应数据
        recipes_data = paged_recipes.map do |recipe|
          format_recipe_summary_optimized(
            recipe,
            products_by_recipe[recipe.recipe_id] || [],
            materials_by_recipe[recipe.recipe_id] || [],
            translations_by_recipe[recipe.recipe_id] || [],
            products_by_recipe[recipe.recipe_id]&.size || 0,
            materials_by_recipe[recipe.recipe_id]&.size || 0
          )
        end

        render_success({
          recipes: recipes_data,
          meta: pagination_meta(paged_recipes, page_params[:page], page_params[:per_page], total_count)
        })
      end

      # GET /api/explorer/recipes/:id
      # 获取配方详情
      def show
        recipe = catalog_provider.find_recipe(params[:id])

        if recipe.nil?
          render_error("配方不存在: #{params[:id]}", :not_found)
          return
        end

        render_success({
          recipe: format_recipe_detail(recipe)
        })
      end

      # GET /api/explorer/recipes/tree/:item_id
      # 获取物品的递归配方树
      def tree
        item_id = params[:item_id].to_i

        if item_id <= 0
          render_error("无效的 item_id: #{params[:item_id]}", :bad_request)
          return
        end

        # 调用 Catalog::RecipeTreeService 计算配方树
        tree_data = Catalog::RecipeTreeService.new(item_id).calculate

        render_success({
          tree: tree_data
        })
      end

      # GET /api/explorer/recipes/products
      # 获取所有可作为产物的物品列表
      def products
        locale = request_locale

        # 使用缓存，缓存键包含语言版本
        cache_key = "explorer:recipes:products:v2:#{catalog_provider.provider_key}:#{locale}"
        products = Rails.cache.fetch(cache_key, expires_in: 6.hours) do
          product_item_ids = catalog_provider.product_item_ids
          # 批量获取物品信息（fetch_items_info内部已有缓存）
          fetch_items_info(product_item_ids, locale)
        end

        render_success(products)
      end

      private

      # 配方摘要格式（列表页）
      def format_recipe_summary(recipe)
        locale = request_locale

        # 获取配方翻译
        translation = translation_for(recipe.translations, locale)

        # 获取产物信息（只取前3个作为预览）
        products = Array(catalog_provider.recipe_products(recipe)).first(3).map do |product|
          {
            item_id: product.item_id,
            item_info: fetch_item_info(product.item_id, locale),
            weight: product.weight || 1,
            min_quantity: product.quantity || 1,
            max_quantity: product.quantity || 1
          }
        end

        # 获取材料信息（只取前3个作为预览）
        materials = Array(catalog_provider.recipe_materials(recipe)).first(3).map do |material|
          {
            item_id: material.item_id,
            item_info: fetch_item_info(material.item_id, locale),
            quantity: material.quantity,
            allow_substitute: false # RecipeMaterials表中没有这个字段
          }
        end

        {
          id: recipe.recipe_id,
          name: translation&.name || "Recipe##{recipe.recipe_id}",
          description: translation&.description,
          enabled: recipe.enabled,
          products_count: Array(catalog_provider.recipe_products(recipe)).size,
          materials_count: Array(catalog_provider.recipe_materials(recipe)).size,
          products_preview: products,
          materials_preview: materials
        }
      end

      # 配方详情格式（详情页）
      def format_recipe_detail(recipe)
        locale = request_locale

        # 获取配方翻译
        translation = translation_for(recipe.translations, locale)

        # 获取所有产物信息
        products = Array(catalog_provider.recipe_products(recipe)).map do |product|
          {
            item_id: product.item_id,
            item_info: fetch_item_info(product.item_id, locale),
            weight: product.weight || 1,
            min_quantity: product.quantity || 1,
            max_quantity: product.quantity || 1
          }
        end

        # 计算产出概率（基于 weight）
        total_weight = products.sum { |p| p[:weight] }
        products.each do |product|
          product[:probability] = total_weight > 0 ? product[:weight].to_f / total_weight : 0
        end

        # 获取所有材料信息
        materials = Array(catalog_provider.recipe_materials(recipe)).map do |material|
          {
            item_id: material.item_id,
            item_info: fetch_item_info(material.item_id, locale),
            quantity: material.quantity,
            allow_substitute: false
          }
        end

        # 获取所有翻译
        translations = recipe.translations&.map do |t|
          {
            locale: t.locale,
            name: t.name,
            description: t.description
          }
        end || []

        {
          id: recipe.recipe_id,
          name: translation&.name || "Recipe##{recipe.recipe_id}",
          description: translation&.description,
          enabled: recipe.enabled,
          translations: translations,
          products: products,
          materials: materials
        }
      end

      # 优化的配方摘要格式（列表页）- 避免N+1查询
      def format_recipe_summary_optimized(recipe, products, materials, translations, products_count, materials_count)
        locale = request_locale

        # 获取配方翻译
        translation = case locale.to_s
                     when 'zh-CN'
                       translations.find { |t| t.locale == 'zh-CN' || t.locale == 'zh' }
                     else
                       translations.find { |t| t.locale == locale.to_s }
                     end ||
                     translations.find { |t| t.locale == 'zh-CN' || t.locale == 'zh' } ||
                     translations.first

        # 获取产物信息（只取前3个作为预览）
        products_preview = products.first(3).map do |product|
          {
            item_id: product.item_id,
            item_info: fetch_item_info(product.item_id, locale),
            weight: product.weight || 1,
            min_quantity: product.quantity || 1,
            max_quantity: product.quantity || 1
          }
        end

        # 获取材料信息（只取前3个作为预览）
        materials_preview = materials.first(3).map do |material|
          {
            item_id: material.item_id,
            item_info: fetch_item_info(material.item_id, locale),
            quantity: material.quantity,
            allow_substitute: false
          }
        end

        {
          id: recipe.recipe_id,
          name: translation&.name || "Recipe##{recipe.recipe_id}",
          description: translation&.description,
          enabled: recipe.enabled,
          products_count: products_count,
          materials_count: materials_count,
          products_preview: products_preview,
          materials_preview: materials_preview
        }
      end

      def parsed_item_ids_filter
        params[:item_ids].to_s.split(',').map(&:to_i).reject(&:zero?).uniq
      end

      def translation_for(translations, locale)
        translations = Array(translations)

        case locale.to_s
        when 'zh-CN'
          translations.find { |t| t.locale == 'zh-CN' || t.locale == 'zh' }
        else
          translations.find { |t| t.locale == locale.to_s }
        end ||
          translations.find { |t| t.locale == 'zh-CN' || t.locale == 'zh' } ||
          translations.first
      end

      def require_recipes_capability
        return if catalog_provider.capabilities[:recipes]

        render_error('Recipes feature is not available for this project', :not_found)
      end
    end
  end
end
