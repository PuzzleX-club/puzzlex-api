# frozen_string_literal: true

module Metadata
  module Catalog
    # Base class for catalog data providers.
    #
    # A catalog provider supplies static item/recipe/translation data for the
    # platform (explorer fallback, recipe tree, admin views, etc.).
    #
    # Subclasses must implement:
    #   - sync_all                → Hash (per-type stats)
    #   - find_item(item_id)      → item record or nil
    #   - find_items(item_ids)    → ActiveRecord::Relation or Array
    #   - find_recipe(recipe_id)  → recipe record or nil
    #   - list_recipes(...)       → Array of recipe records
    #   - find_recipes_by_product(item_id) → Array of recipe records
    #   - recipe_products(recipe) → Array of recipe product records
    #   - recipe_materials(recipe) → Array of recipe material records
    #   - product_item_ids        → Array<Integer>
    #   - enabled?                → Boolean
    #
    class BaseProvider
      def provider_key
        raise NotImplementedError, "#{self.class}#provider_key must be implemented"
      end

      def sync_all
        raise NotImplementedError, "#{self.class}#sync_all must be implemented"
      end

      def find_item(_item_id)
        raise NotImplementedError, "#{self.class}#find_item must be implemented"
      end

      def find_items(_item_ids)
        raise NotImplementedError, "#{self.class}#find_items must be implemented"
      end

      def find_recipe(_recipe_id)
        raise NotImplementedError, "#{self.class}#find_recipe must be implemented"
      end

      def list_recipes(keyword: nil, item_id: nil, item_ids: [])
        raise NotImplementedError, "#{self.class}#list_recipes must be implemented"
      end

      def find_recipes_by_product(_item_id)
        raise NotImplementedError, "#{self.class}#find_recipes_by_product must be implemented"
      end

      def recipe_products(_recipe)
        raise NotImplementedError, "#{self.class}#recipe_products must be implemented"
      end

      def recipe_materials(_recipe)
        raise NotImplementedError, "#{self.class}#recipe_materials must be implemented"
      end

      def product_item_ids
        raise NotImplementedError, "#{self.class}#product_item_ids must be implemented"
      end

      def enabled?
        raise NotImplementedError, "#{self.class}#enabled? must be implemented"
      end

      # Returns a hash of provider capabilities.
      # Subclasses should override to declare supported features.
      #
      # Standard capability keys:
      #   marketplace: true/false  — provider fills sellable field
      #   minting: true/false      — provider fills can_mint field
      #   recipes: true/false      — provider manages recipe tables
      #   filterable_fields: [{ key:, type:, source: }]
      #   facet_fields: ['field1', 'field2']
      #   extension_fields: ['field1', 'field2']  — whitelist for API advance extra fields
      #
      def capabilities
        {}
      end
    end
  end
end
