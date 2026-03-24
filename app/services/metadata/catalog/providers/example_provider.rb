# frozen_string_literal: true

module Metadata
  module Catalog
    module Providers
      # Example catalog provider for OSS demo / smoke testing.
      #
      # Reads static JSON fixtures from backend/examples/catalog/
      # and returns lightweight PORO objects that are duck-type compatible
      # with CatalogData::Item (consumed by ItemDTO, ItemQueryService, etc.).
      #
      # No database, no private repo, no external API required.
      #
      class ExampleProvider < BaseProvider
        def provider_key
          'example'
        end

        def sync_all
          { items: { loaded: items_data.size }, recipes: { loaded: recipes_data.size } }
        end

        def find_item(item_id)
          id = item_id.to_i
          data = items_data.find { |d| d['item_id'] == id }
          return nil unless data

          build_item(data)
        end

        def find_items(item_ids)
          ids = Array(item_ids).map(&:to_i)
          items_data
            .select { |d| ids.include?(d['item_id']) }
            .map { |d| build_item(d) }
        end

        def find_recipe(recipe_id)
          id = recipe_id.to_i
          data = recipes_data.find { |d| d['recipe_id'] == id }
          return nil unless data

          build_recipe(data)
        end

        def list_recipes(keyword: nil, item_id: nil, item_ids: [])
          recipes = recipes_data.map { |data| build_recipe(data) }

          if keyword.present?
            normalized_keyword = keyword.to_s.strip.downcase
            recipes = recipes.select do |recipe|
              recipe.translations.any? do |translation|
                translation.name.to_s.downcase.include?(normalized_keyword) ||
                  translation.description.to_s.downcase.include?(normalized_keyword)
              end
            end
          end

          product_ids = normalize_product_filter_ids(item_id: item_id, item_ids: item_ids)
          if product_ids.any?
            recipes = recipes.select do |recipe|
              recipe.products.any? { |product| product_ids.include?(product.item_id.to_i) }
            end
          end

          recipes.sort_by { |recipe| -recipe.recipe_id.to_i }
        end

        def find_recipes_by_product(item_id)
          id = item_id.to_i
          return [] if id <= 0

          recipes_data
            .select { |data| Array(data['products']).any? { |product| product['item_id'].to_i == id } }
            .map { |data| build_recipe(data) }
        end

        def recipe_products(recipe)
          resolved_recipe = resolve_recipe(recipe)
          resolved_recipe ? resolved_recipe.products : []
        end

        def recipe_materials(recipe)
          resolved_recipe = resolve_recipe(recipe)
          resolved_recipe ? resolved_recipe.materials : []
        end

        def product_item_ids
          recipes_data
            .flat_map { |data| Array(data['products']).map { |product| product['item_id'].to_i } }
            .reject(&:zero?)
            .uniq
        end

        def enabled?
          true
        end

        def capabilities
          {
            marketplace: true,
            minting: true,
            recipes: true,
            filterable_fields: [
              { key: 'item_type', type: :integer, source: :column }
            ],
            facet_fields: %w[item_type],
            extension_fields: %w[sub_type quality use_level talent_ids wealth_value]
          }
        end

        private

        def items_data
          @items_data ||= load_json('items.json')
        end

        def recipes_data
          @recipes_data ||= load_json('recipes.json')
        end

        def load_json(filename)
          path = Rails.root.join('examples', 'catalog', filename)
          return [] unless File.exist?(path)

          JSON.parse(File.read(path))
        rescue JSON::ParserError => e
          Rails.logger.error "[ExampleCatalogProvider] Failed to parse #{filename}: #{e.message}"
          []
        end

        def build_item(data)
          translations = (data['translations'] || []).map do |t|
            ExampleTranslation.new(
              locale: t['locale'],
              name: t['name'],
              description: t['description']
            )
          end

          # Build extra_data from any non-canonical fields in the JSON fixture
          extra_data = (data['extra_data'] || {}).merge(
            data.slice(
              'sub_type', 'quality', 'talent_ids', 'use_level',
              'wealth_value', 'drop_scenes', 'booth_fees', 'destructible',
              'given_skill_id', 'on_chain_delay', 'resource_instructions',
              'token_task_level', 'token_task_refresh_type', 'user_type'
            ).compact
          )

          ExampleItem.new(
            item_id:      data['item_id'],
            icon:         data['icon'],
            item_type:    data['item_type'],
            can_mint:     data['can_mint'],
            sellable:     data['sellable'],
            enabled:      data['enabled'],
            source_hash:  data['source_hash'],
            extra_data:   extra_data,
            translations: translations,
            updated_at:   Time.current
          )
        end

        def build_recipe(data)
          translations = (data['translations'] || []).map do |translation|
            ExampleRecipeTranslation.new(
              locale: translation['locale'],
              name: translation['name'],
              description: translation['description']
            )
          end

          products = (data['products'] || []).map do |product|
            ExampleRecipeProduct.new(
              recipe_id: data['recipe_id'],
              item_id: product['item_id'],
              quantity: product['quantity'],
              weight: product['weight']
            )
          end

          materials = (data['materials'] || []).map do |material|
            ExampleRecipeMaterial.new(
              recipe_id: data['recipe_id'],
              item_id: material['item_id'],
              quantity: material['quantity']
            )
          end

          ExampleRecipe.new(
            recipe_id: data['recipe_id'],
            enabled: data['enabled'],
            translations: translations,
            products: products,
            materials: materials
          )
        end

        def resolve_recipe(recipe)
          return recipe if recipe.respond_to?(:recipe_id) && recipe.respond_to?(:products) && recipe.respond_to?(:materials)

          find_recipe(recipe)
        end

        def normalize_product_filter_ids(item_id:, item_ids:)
          if item_id.present?
            [item_id.to_i].reject(&:zero?)
          else
            Array(item_ids).map(&:to_i).reject(&:zero?).uniq
          end
        end

        # Lightweight PORO that duck-types CatalogData::Item for DTO consumption.
        # Canonical fields + extra_data JSONB for project-specific extensions.
        ExampleItem = Struct.new(
          :item_id, :icon, :item_type, :can_mint, :sellable, :enabled,
          :source_hash, :extra_data, :translations, :updated_at,
          keyword_init: true
        ) do
          def extra(key, default = nil)
            key = key.to_s
            data = extra_data || {}
            return default unless data.key?(key)

            data[key]
          end
        end

        # Lightweight PORO that duck-types CatalogData::ItemTranslation.
        ExampleTranslation = Struct.new(
          :locale, :name, :description,
          keyword_init: true
        )

        ExampleRecipe = Struct.new(
          :recipe_id, :enabled, :translations, :products, :materials,
          keyword_init: true
        )

        ExampleRecipeTranslation = Struct.new(
          :locale, :name, :description,
          keyword_init: true
        )

        ExampleRecipeProduct = Struct.new(
          :recipe_id, :item_id, :quantity, :weight,
          keyword_init: true
        )

        ExampleRecipeMaterial = Struct.new(
          :recipe_id, :item_id, :quantity,
          keyword_init: true
        )
      end
    end
  end
end
