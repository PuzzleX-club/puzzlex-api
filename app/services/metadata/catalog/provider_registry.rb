# frozen_string_literal: true

module Metadata
  module Catalog
    # Registry for catalog data providers.
    #
    # Reads `config.x.catalog.provider` to select the active provider.
    # Supported keys: :repo_sync, :example, :none
    #
    class ProviderRegistry
      class << self
        # Returns the currently configured provider instance.
        # Memoized per-process; call `reset!` in tests.
        def current
          @current ||= build_provider
        end

        # Force re-read of config (useful in tests).
        def reset!
          @current = nil
        end

        private

        def build_provider
          key = Rails.application.config.x.catalog.provider

          case key
          when :repo_sync
            Providers::RepoSync::Provider.new
          when :example
            Providers::ExampleProvider.new if defined?(Providers::ExampleProvider)
          when :none
            NullProvider.new
          else
            Rails.logger&.warn "[Catalog] Unknown provider '#{key}', falling back to :none"
            NullProvider.new
          end || NullProvider.new
        end
      end

      # Null provider — always disabled, returns empty results.
      class NullProvider < BaseProvider
        def provider_key
          'none'
        end

        def sync_all
          {}
        end

        def find_item(_item_id)
          nil
        end

        def find_items(_item_ids)
          []
        end

        def find_recipe(_recipe_id)
          nil
        end

        def list_recipes(keyword: nil, item_id: nil, item_ids: [])
          []
        end

        def find_recipes_by_product(_item_id)
          []
        end

        def recipe_products(_recipe)
          []
        end

        def recipe_materials(_recipe)
          []
        end

        def product_item_ids
          []
        end

        def enabled?
          false
        end

        def capabilities
          {}
        end
      end
    end
  end
end
