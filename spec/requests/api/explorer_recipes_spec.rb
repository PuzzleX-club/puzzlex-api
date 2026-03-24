# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Explorer Recipes API', type: :request do
  let!(:product_item) { create(:catalog_item, :with_translations, item_id: 80_050) }
  let!(:material_item_1) { create(:catalog_item, :with_translations, item_id: 80_051) }
  let!(:material_item_2) { create(:catalog_item, :with_translations, item_id: 80_052) }

  let!(:recipe) do
    create(:catalog_recipe, recipe_id: 1001, enabled: true)
  end
  let!(:recipe_translation_zh) do
    create(:catalog_recipe_translation, recipe: recipe, locale: 'zh', name: '高级武器配方', description: '用于制作高级武器')
  end
  let!(:recipe_translation_en) do
    create(:catalog_recipe_translation, recipe: recipe, locale: 'en', name: 'Advanced Weapon Recipe', description: 'Used to craft advanced weapons')
  end
  let!(:recipe_product) do
    create(:catalog_recipe_product, recipe: recipe, item: product_item, quantity: 1, weight: 80)
  end
  let!(:recipe_material_1) do
    create(:catalog_recipe_material, recipe: recipe, item: material_item_1, quantity: 3)
  end
  let!(:recipe_material_2) do
    create(:catalog_recipe_material, recipe: recipe, item: material_item_2, quantity: 5)
  end

  let!(:disabled_recipe) do
    create(:catalog_recipe, recipe_id: 1002, enabled: false)
  end

  # ============================================
  # GET /api/explorer/recipes
  # ============================================
  describe 'GET /api/explorer/recipes' do
    it 'returns enabled recipes with pagination' do
      get '/api/explorer/recipes'
      expect(response).to have_http_status(:ok)
      json = JSON.parse(response.body)
      expect(json['data']['recipes']).to be_an(Array)
      # Only enabled recipes
      recipe_ids = json['data']['recipes'].map { |r| r['id'] }
      expect(recipe_ids).to include(1001)
      expect(recipe_ids).not_to include(1002)
      expect(json['data']['meta']).to have_key('total_count')
    end

    it 'searches by keyword' do
      get '/api/explorer/recipes', params: { keyword: '武器' }
      json = JSON.parse(response.body)
      expect(json['data']['recipes'].length).to be >= 1
      recipe_ids = json['data']['recipes'].map { |r| r['id'] }
      expect(recipe_ids).to include(1001)
    end

    it 'returns empty for non-matching keyword' do
      get '/api/explorer/recipes', params: { keyword: 'nonexistent' }
      json = JSON.parse(response.body)
      expect(json['data']['recipes']).to be_empty
    end

    it 'filters by item_id (product item)' do
      get '/api/explorer/recipes', params: { item_id: product_item.item_id }
      json = JSON.parse(response.body)
      expect(json['data']['recipes'].length).to eq(1)
    end

    it 'supports pagination parameters' do
      get '/api/explorer/recipes', params: { page: 1, per_page: 5 }
      json = JSON.parse(response.body)
      expect(json['data']['meta']['per_page']).to eq(5)
    end

    it 'includes products_preview and materials_preview' do
      get '/api/explorer/recipes'
      json = JSON.parse(response.body)
      recipe_data = json['data']['recipes'].find { |r| r['id'] == 1001 }
      expect(recipe_data).to be_present
      expect(recipe_data).to have_key('products_preview')
      expect(recipe_data).to have_key('materials_preview')
      expect(recipe_data).to have_key('products_count')
      expect(recipe_data).to have_key('materials_count')
    end
  end

  # ============================================
  # GET /api/explorer/recipes/:id
  # ============================================
  describe 'GET /api/explorer/recipes/:id' do
    it 'returns recipe detail with products and materials' do
      get "/api/explorer/recipes/#{recipe.recipe_id}"
      expect(response).to have_http_status(:ok)
      json = JSON.parse(response.body)
      data = json['data']['recipe']
      expect(data['id']).to eq(1001)
      expect(data['products']).to be_an(Array)
      expect(data['products'].length).to eq(1)
      expect(data['products'].first['item_id']).to eq(product_item.item_id)
      expect(data['products'].first).to have_key('probability')
      expect(data['materials']).to be_an(Array)
      expect(data['materials'].length).to eq(2)
      expect(data['translations']).to be_an(Array)
    end

    it 'returns error for non-existent recipe' do
      get '/api/explorer/recipes/999999'
      expect(response).to have_http_status(:not_found)
    end
  end

  # ============================================
  # GET /api/explorer/recipes/tree/:item_id
  # ============================================
  describe 'GET /api/explorer/recipes/tree/:item_id' do
    it 'returns recipe tree for an item' do
      get "/api/explorer/recipes/tree/#{product_item.item_id}"
      expect(response).to have_http_status(:ok)
      json = JSON.parse(response.body)
      tree = json['data']['tree']
      expect(tree['item_id']).to eq(product_item.item_id)
      expect(tree['is_base_material']).to be false
      expect(tree['recipes']).to be_an(Array)
      expect(tree['recipes'].length).to eq(1)
    end

    it 'returns base material node when no recipes exist' do
      get "/api/explorer/recipes/tree/#{material_item_1.item_id}"
      json = JSON.parse(response.body)
      tree = json['data']['tree']
      expect(tree['item_id']).to eq(material_item_1.item_id)
      expect(tree['is_base_material']).to be true
      expect(tree['recipes']).to be_empty
    end

    it 'returns error for invalid item_id' do
      get '/api/explorer/recipes/tree/0'
      expect(response).to have_http_status(:bad_request)
    end
  end

  # ============================================
  # GET /api/explorer/recipes/products
  # ============================================
  describe 'GET /api/explorer/recipes/products' do
    it 'returns all product items' do
      get '/api/explorer/recipes/products'
      expect(response).to have_http_status(:ok)
      json = JSON.parse(response.body)
      expect(json['data']).to be_an(Array)
    end
  end

  context 'when catalog provider is example' do
    around do |example|
      original_provider = Rails.application.config.x.catalog.provider
      Rails.application.config.x.catalog.provider = :example
      Metadata::Catalog::ProviderRegistry.reset!
      Rails.cache.clear

      example.run
    ensure
      Rails.application.config.x.catalog.provider = original_provider
      Metadata::Catalog::ProviderRegistry.reset!
      Rails.cache.clear
    end

    it 'returns recipes from example fixtures' do
      get '/api/explorer/recipes'
      expect(response).to have_http_status(:ok)
      json = JSON.parse(response.body)

      recipe_ids = json['data']['recipes'].map { |recipe_data| recipe_data['id'] }
      expect(recipe_ids).to include(1, 2)
    end

    it 'builds recipe tree from example fixtures' do
      get '/api/explorer/recipes/tree/1'
      expect(response).to have_http_status(:ok)
      json = JSON.parse(response.body)

      tree = json['data']['tree']
      expect(tree['item_id']).to eq(1)
      expect(tree['is_base_material']).to be false
      expect(tree['recipes'].first['recipe_id']).to eq(1)
    end
  end

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

    it 'returns not found for recipe endpoints' do
      get '/api/explorer/recipes'
      expect(response).to have_http_status(:not_found)

      get "/api/explorer/recipes/tree/#{product_item.item_id}"
      expect(response).to have_http_status(:not_found)

      get '/api/explorer/recipes/products'
      expect(response).to have_http_status(:not_found)
    end
  end
end
