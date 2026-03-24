# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Catalog::RecipeTreeService do
  let!(:base_material) { create(:catalog_item, :with_translations, item_id: 80_060) }
  let!(:intermediate_item) { create(:catalog_item, :with_translations, item_id: 80_061) }
  let!(:final_product) { create(:catalog_item, :with_translations, item_id: 80_062) }

  # Recipe: base_material + intermediate -> final_product
  let!(:final_recipe) do
    create(:catalog_recipe, :with_translations, recipe_id: 2001, enabled: true)
  end
  let!(:final_product_link) do
    create(:catalog_recipe_product, recipe: final_recipe, item: final_product, quantity: 1, weight: 100)
  end
  let!(:final_material_1) do
    create(:catalog_recipe_material, recipe: final_recipe, item: base_material, quantity: 2)
  end
  let!(:final_material_2) do
    create(:catalog_recipe_material, recipe: final_recipe, item: intermediate_item, quantity: 1)
  end

  # Recipe: base_material -> intermediate_item
  let!(:intermediate_recipe) do
    create(:catalog_recipe, :with_translations, recipe_id: 2002, enabled: true)
  end
  let!(:intermediate_product_link) do
    create(:catalog_recipe_product, recipe: intermediate_recipe, item: intermediate_item, quantity: 1, weight: 50)
  end
  let!(:intermediate_material) do
    create(:catalog_recipe_material, recipe: intermediate_recipe, item: base_material, quantity: 5)
  end

  describe '#calculate' do
    context 'when recipes capability is disabled' do
      around do |example|
        original_provider = Rails.application.config.x.catalog.provider
        Rails.application.config.x.catalog.provider = :none
        Metadata::Catalog::ProviderRegistry.reset!

        example.run
      ensure
        Rails.application.config.x.catalog.provider = original_provider
        Metadata::Catalog::ProviderRegistry.reset!
      end

      it 'raises an explicit recipes-disabled error at the top level' do
        expect do
          described_class.new(base_material.item_id).calculate
        end.to raise_error(
          Catalog::RecipeTreeService::RecipesDisabledError,
          'Recipes feature is not available for this project'
        )
      end
    end

    it 'returns base material node when item has no recipes' do
      service = described_class.new(base_material.item_id)
      result = service.calculate

      expect(result[:item_id]).to eq(base_material.item_id)
      expect(result[:is_base_material]).to be true
      expect(result[:recipes]).to be_empty
    end

    it 'returns single recipe tree for intermediate item' do
      service = described_class.new(intermediate_item.item_id)
      result = service.calculate

      expect(result[:item_id]).to eq(intermediate_item.item_id)
      expect(result[:is_base_material]).to be false
      expect(result[:recipes].length).to eq(1)
      recipe_node = result[:recipes].first
      expect(recipe_node[:recipe_id]).to eq(2002)
      expect(recipe_node[:materials].length).to eq(1)
      # Material should be base_material, which is a leaf
      expect(recipe_node[:materials].first[:sub_tree][:is_base_material]).to be true
    end

    it 'builds recursive tree for final product' do
      service = described_class.new(final_product.item_id)
      result = service.calculate

      expect(result[:item_id]).to eq(final_product.item_id)
      expect(result[:is_base_material]).to be false
      expect(result[:recipes].length).to eq(1)

      recipe_node = result[:recipes].first
      expect(recipe_node[:materials].length).to eq(2)

      # Find the intermediate material in the recipe
      intermediate_mat = recipe_node[:materials].find { |m| m[:item_id] == intermediate_item.item_id }
      expect(intermediate_mat).to be_present
      # The intermediate item should have its own sub-tree with a recipe
      expect(intermediate_mat[:sub_tree][:is_base_material]).to be false
      expect(intermediate_mat[:sub_tree][:recipes].length).to eq(1)
    end

    it 'detects circular dependencies' do
      # Create circular: item_70 -> recipe uses item_71 -> recipe uses item_70
      circular_a = create(:catalog_item, item_id: 80_070)
      circular_b = create(:catalog_item, item_id: 80_071)

      recipe_a = create(:catalog_recipe, recipe_id: 3001, enabled: true)
      create(:catalog_recipe_product, recipe: recipe_a, item: circular_a, quantity: 1, weight: 1)
      create(:catalog_recipe_material, recipe: recipe_a, item: circular_b, quantity: 1)

      recipe_b = create(:catalog_recipe, recipe_id: 3002, enabled: true)
      create(:catalog_recipe_product, recipe: recipe_b, item: circular_b, quantity: 1, weight: 1)
      create(:catalog_recipe_material, recipe: recipe_b, item: circular_a, quantity: 1)

      service = described_class.new(circular_a.item_id)
      result = service.calculate

      # Should complete without infinite recursion; circular reference becomes base material
      expect(result[:is_base_material]).to be false
      expect(result[:recipes]).to be_present
    end

    it 'respects MAX_DEPTH protection' do
      service = described_class.new(base_material.item_id, depth: Catalog::RecipeTreeService::MAX_DEPTH)
      result = service.calculate

      expect(result[:is_base_material]).to be true
      expect(result[:recipes]).to be_empty
    end

    it 'calculates product probabilities based on weight' do
      # Add a second product to the intermediate recipe
      second_product = create(:catalog_item, item_id: 80_063)
      create(:catalog_recipe_product, recipe: intermediate_recipe, item: second_product, quantity: 1, weight: 50)

      service = described_class.new(intermediate_item.item_id)
      result = service.calculate

      recipe_node = result[:recipes].first
      products = recipe_node[:products]
      expect(products.length).to eq(2)
      # Each has weight 50, total 100, so probability = 0.5
      products.each do |p|
        expect(p[:probability]).to eq(0.5)
      end
    end

    it 'returns fallback info for non-existent item' do
      service = described_class.new(999_999)
      result = service.calculate

      expect(result[:item_id]).to eq(999_999)
      expect(result[:is_base_material]).to be true
      expect(result[:item_name]).to include('Unknown')
    end

    it 'includes item_info in tree nodes' do
      service = described_class.new(final_product.item_id)
      result = service.calculate

      expect(result[:item_info]).to be_present
      expect(result[:item_info][:item_id]).to eq(final_product.item_id)
    end
  end
end
