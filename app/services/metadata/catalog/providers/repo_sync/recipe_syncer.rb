# frozen_string_literal: true

module Metadata
  module Catalog
    module Providers
      module RepoSync
        # Persists parsed recipe data to CatalogData::Recipe and associations.
        #
        class RecipeSyncer
          class << self
            # Sync recipes from parsed CSV contents.
            # @param csv_contents [Hash] { locale => csv_string }
            # @return [Hash] stats
            def sync(csv_contents)
              recipes_data = CsvParser.parse_multi_language(csv_contents, 'Recipes')
              stats = { created: 0, updated: 0, unchanged: 0, translations: { created: 0, updated: 0 }, errors: [] }

              recipes_data.each do |recipe_data|
                sync_single_recipe(recipe_data, stats)
              rescue StandardError => e
                Rails.logger.error "[RepoSync::RecipeSyncer] recipe ##{recipe_data[:recipe_id]} failed: #{e.message}"
                stats[:errors] << { recipe_id: recipe_data[:recipe_id], error: e.message }
              end

              disable_absent_recipes(recipes_data, stats)

              Rails.logger.info "[RepoSync::RecipeSyncer] done: created=#{stats[:created]} updated=#{stats[:updated]} " \
                                "unchanged=#{stats[:unchanged]} disabled=#{stats[:disabled]} errors=#{stats[:errors].size}"
              stats
            end

            private

            def sync_single_recipe(recipe_data, stats)
              recipe = CatalogData::Recipe.find_or_initialize_by(recipe_id: recipe_data[:recipe_id])

              base_attributes = recipe_data.except(:translations, :parsed, :recipe_id, :materials, :products)

              old_hash = recipe.source_hash
              recipe.assign_attributes(base_attributes)
              new_hash = recipe.calculate_source_hash

              if recipe.new_record?
                recipe.save!
                stats[:created] += 1
              elsif old_hash != new_hash
                recipe.save!
                stats[:updated] += 1
              else
                stats[:unchanged] += 1
              end

              update_materials(recipe, recipe_data[:materials]) if recipe_data[:materials]
              update_products(recipe, recipe_data[:products]) if recipe_data[:products]

              translation_stats = sync_translations(recipe, recipe_data[:translations])
              stats[:translations][:created] += translation_stats[:created]
              stats[:translations][:updated] += translation_stats[:updated]
            end

            def sync_translations(recipe, translations)
              stats = { created: 0, updated: 0 }

              translations.each do |locale, attrs|
                translation = recipe.translations.find_or_initialize_by(locale: locale)

                old_hash = translation.translation_hash
                translation.assign_attributes(attrs)
                new_hash = translation.calculate_translation_hash

                if translation.new_record?
                  translation.save!
                  stats[:created] += 1
                elsif old_hash != new_hash
                  translation.save!
                  stats[:updated] += 1
                end
              end

              stats
            end

            def update_materials(recipe, materials)
              recipe.materials.delete_all

              materials.each do |item_id, quantity|
                item = CatalogData::Item.find_by(item_id: item_id)
                next unless item

                recipe.materials.create!(item: item, quantity: quantity)
              end
            end

            def update_products(recipe, products)
              recipe.products.delete_all

              products.each do |product_data|
                item = CatalogData::Item.find_by(item_id: product_data[:item_id])
                next unless item

                recipe.products.create!(
                  item: item,
                  quantity: product_data[:quantity],
                  weight: product_data[:weight] || 0,
                  product_type: product_data[:product_type] || 0
                )
              end
            end

            def disable_absent_recipes(recipes_data, stats)
              recipe_ids_in_repo = recipes_data.map { |r| r[:recipe_id] }
              disabled_count = CatalogData::Recipe
                .where.not(recipe_id: recipe_ids_in_repo)
                .where(enabled: true)
                .update_all(enabled: false, updated_at: Time.current)

              Rails.logger.info "[RepoSync::RecipeSyncer] disabled #{disabled_count} absent recipes" if disabled_count > 0
              stats[:disabled] = disabled_count
            end
          end
        end
      end
    end
  end
end
