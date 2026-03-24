# frozen_string_literal: true

module Metadata
  module Catalog
    module Providers
      module RepoSync
        # Full repo-sync catalog provider implementation.
        #
        # Orchestrates: fetch → parse → persist for items and recipes.
        # Acts as the canonical catalog sync entry point.
        #
        class Provider < BaseProvider
          def provider_key
            'repo_sync'
          end

          def sync_all
            results = {}
            results[:items] = sync_items
            results[:recipes] = sync_recipes

            Rails.logger.info "[RepoSyncCatalog] sync_all complete: #{results}"
            results
          end

          def sync_items
            Rails.logger.info "[RepoSyncCatalog] syncing items"

            fetch_result = Fetcher.fetch_all_languages('Item')
            csv_contents = fetch_result[:contents]

            log_fetch_errors(fetch_result[:errors]) if fetch_result[:errors].any?

            stats = ItemSyncer.sync(csv_contents)
            Rails.logger.info "[RepoSyncCatalog] items sync stats: #{stats}"
            stats
          rescue StandardError => e
            Rails.logger.error "[RepoSyncCatalog] items sync failed: #{e.message}"
            Rails.logger.error e.backtrace.first(5).join("\n")
            { success: false, error: e.message }
          end

          def sync_recipes
            Rails.logger.info "[RepoSyncCatalog] syncing recipes"

            fetch_result = Fetcher.fetch_all_languages('Recipes')
            csv_contents = fetch_result[:contents]

            log_fetch_errors(fetch_result[:errors]) if fetch_result[:errors].any?

            stats = RecipeSyncer.sync(csv_contents)
            Rails.logger.info "[RepoSyncCatalog] recipes sync stats: #{stats}"
            stats
          rescue StandardError => e
            Rails.logger.error "[RepoSyncCatalog] recipes sync failed: #{e.message}"
            Rails.logger.error e.backtrace.first(5).join("\n")
            { success: false, error: e.message }
          end

          def sync_from_local_file(file_path, file_type = 'Item', locale = 'zh-CN')
            Rails.logger.info "[RepoSyncCatalog] syncing from local file: #{file_path}"

            csv_content = File.read(file_path, encoding: 'UTF-8')
            csv_contents = { locale => csv_content }

            case file_type
            when 'Item'
              ItemSyncer.sync(csv_contents)
            when 'Recipes'
              RecipeSyncer.sync(csv_contents)
            else
              raise ArgumentError, "Unsupported file type: #{file_type}"
            end
          rescue StandardError => e
            Rails.logger.error "[RepoSyncCatalog] local file sync failed: #{e.message}"
            { success: false, error: e.message }
          end

          def find_item(item_id)
            CatalogData::Item.find_by(item_id: item_id.to_i)
          end

          def find_items(item_ids)
            ids = Array(item_ids).map(&:to_i).reject(&:zero?)
            CatalogData::Item.where(item_id: ids)
          end

          def find_recipe(recipe_id)
            rid = recipe_id.to_i
            return nil if rid <= 0

            CatalogData::Recipe
              .includes(:translations)
              .find_by(recipe_id: rid)
          end

          def list_recipes(keyword: nil, item_id: nil, item_ids: [])
            recipes = CatalogData::Recipe.enabled.includes(:translations)

            if keyword.present?
              normalized_keyword = keyword.to_s.strip.downcase
              recipes = recipes
                .joins(:translations)
                .where("LOWER(#{CatalogData::RecipeTranslation.table_name}.name) LIKE ?", "%#{normalized_keyword}%")
            end

            product_ids = normalize_product_filter_ids(item_id: item_id, item_ids: item_ids)
            if product_ids.any?
              recipes = recipes
                .joins("INNER JOIN #{CatalogData::RecipeProduct.table_name} ON #{CatalogData::RecipeProduct.table_name}.recipe_id = #{CatalogData::Recipe.table_name}.recipe_id")
                .where("#{CatalogData::RecipeProduct.table_name}.item_id IN (?)", product_ids)
                .group("#{CatalogData::Recipe.table_name}.recipe_id")
            end

            recipes.order("#{CatalogData::Recipe.table_name}.recipe_id DESC").to_a
          end

          def find_recipes_by_product(item_id)
            rid = item_id.to_i
            return [] if rid <= 0

            recipe_ids = CatalogData::RecipeProduct
              .where(item_id: rid)
              .pluck(:recipe_id)
              .uniq

            return [] if recipe_ids.empty?

            CatalogData::Recipe
              .where(recipe_id: recipe_ids)
              .where(enabled: true)
              .includes(:translations)
              .order(:recipe_id)
              .to_a
          end

          def recipe_products(recipe)
            CatalogData::RecipeProduct
              .where(recipe_id: extract_recipe_id(recipe))
              .order(:id)
              .to_a
          end

          def recipe_materials(recipe)
            CatalogData::RecipeMaterial
              .where(recipe_id: extract_recipe_id(recipe))
              .order(:id)
              .to_a
          end

          def product_item_ids
            CatalogData::RecipeProduct.reorder(nil).distinct.pluck(:item_id)
          end

          def enabled?
            config[:enabled]
          end

          def capabilities
            {
              marketplace: true,
              minting: true,
              recipes: true,
              filterable_fields: [
                { key: 'item_type', type: :integer, source: :column },
                { key: 'use_level', type: :integer, source: :extra_data },
                { key: 'talent_ids', type: :integer_array, source: :extra_data }
              ],
              facet_fields: %w[item_type use_level talent_ids],
              extension_fields: %w[sub_type quality use_level talent_ids wealth_value drop_scenes
                                   booth_fees destructible given_skill_id on_chain_delay
                                   resource_instructions token_task_level token_task_refresh_type user_type]
            }
          end

          private

          def config
            Rails.application.config.x.catalog.providers.repo_sync
          end

          def log_fetch_errors(errors)
            Rails.logger.warn "[RepoSyncCatalog] partial fetch failures: #{errors}"
          end

          def normalize_product_filter_ids(item_id:, item_ids:)
            if item_id.present?
              [item_id.to_i].reject(&:zero?)
            else
              Array(item_ids).map(&:to_i).reject(&:zero?).uniq
            end
          end

          def extract_recipe_id(recipe)
            recipe.respond_to?(:recipe_id) ? recipe.recipe_id : recipe.to_i
          end
        end
      end
    end
  end
end
