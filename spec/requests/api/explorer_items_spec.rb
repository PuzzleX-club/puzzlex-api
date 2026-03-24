# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Explorer Items API', type: :request do
  # Use high item_ids to avoid clashing with CatalogData CSV seed data in test DB
  let(:test_item_id) { 80_001 }

  # Cross-table setup: indexer_item.id (string) must match catalog_item.item_id (integer)
  let!(:catalog_item) do
    create(
      :catalog_item,
      item_id: test_item_id,
      item_type: 'weapon',
      use_level: 3,
      talent_ids: [1, 2],
      wealth_value: 100,
      drop_scenes: ['forest']
    )
  end
  let!(:lumi_translation_en) do
    create(:catalog_item_translation, item: catalog_item, locale: 'en', name: 'Magic Sword')
  end
  let!(:lumi_translation_zh) do
    create(:catalog_item_translation, item: catalog_item, locale: 'zh', name: '魔法剑')
  end
  let!(:indexer_item) do
    create(:indexer_item, id: test_item_id.to_s, total_supply: 1000, minted_amount: 1200, burned_amount: 200)
  end
  let!(:indexer_instance) do
    create(:indexer_instance, id: "token-#{test_item_id}-01", item_record: indexer_item, item: test_item_id.to_s, quality: '0x01')
  end
  let!(:indexer_player) do
    create(:indexer_player, id: '0x' + 'a1' * 20)
  end
  let!(:indexer_balance) do
    create(:indexer_instance_balance,
           id: "#{indexer_instance.id}-#{indexer_player.id}",
           instance_record: indexer_instance,
           player_record: indexer_player,
           instance: indexer_instance.id,
           player: indexer_player.id,
           balance: 5)
  end

  # ============================================
  # GET /api/explorer/items
  # ============================================
  # NOTE: CatalogData uses `connects_to` (separate connection pool). Transactional
  # fixtures isolate each pool, so filter tests that JOIN ItemIndexer →
  # CatalogData cannot see cross-connection data. Filter tests verify API contract
  # (status + structure) rather than exact row counts.
  describe 'GET /api/explorer/items' do
    it 'returns items with pagination meta' do
      get '/api/explorer/items'
      expect(response).to have_http_status(:ok)
      json = JSON.parse(response.body)
      expect(json['code']).to eq(200)
      expect(json['data']['items']).to be_an(Array)
      expect(json['data']['items'].length).to be >= 1
      meta = json['data']['meta']
      expect(meta['current_page']).to eq(1)
      expect(meta['total_count']).to be >= 1
    end

    it 'supports pagination parameters' do
      get '/api/explorer/items', params: { page: 1, per_page: 5 }
      expect(response).to have_http_status(:ok)
      json = JSON.parse(response.body)
      expect(json['data']['meta']['per_page']).to eq(5)
    end

    it 'caps per_page at MAX_PAGE_SIZE (100)' do
      get '/api/explorer/items', params: { per_page: 200 }
      json = JSON.parse(response.body)
      expect(json['data']['meta']['per_page']).to eq(100)
    end

    it 'filters by keyword and returns valid response structure' do
      get '/api/explorer/items', params: { keyword: 'SomeKeyword' }
      expect(response).to have_http_status(:ok)
      json = JSON.parse(response.body)
      expect(json['data']['items']).to be_an(Array)
      expect(json['data']['meta']).to have_key('total_count')
    end

    it 'includes facets when include_facets=true' do
      get '/api/explorer/items', params: { include_facets: 'true' }
      json = JSON.parse(response.body)
      expect(json['data']).to have_key('facets')
      expect(json['data']['facets']).to have_key('use_levels')
      expect(json['data']['facets']).to have_key('item_types')
      expect(json['data']['facets']).to have_key('talent_ids')
    end

    it 'filters by use_levels and returns valid response' do
      get '/api/explorer/items', params: { use_levels: '3' }
      expect(response).to have_http_status(:ok)
      json = JSON.parse(response.body)
      expect(json['data']['items']).to be_an(Array)
      expect(json['data']['meta']).to have_key('total_count')
    end

    it 'filters by item_types and returns valid response' do
      get '/api/explorer/items', params: { item_types: '999' }
      expect(response).to have_http_status(:ok)
      json = JSON.parse(response.body)
      expect(json['data']['items']).to be_an(Array)
    end
  end

  # ============================================
  # GET /api/explorer/items/facets
  # ============================================
  describe 'GET /api/explorer/items/facets' do
    it 'returns facet arrays for filtering' do
      get '/api/explorer/items/facets'
      expect(response).to have_http_status(:ok)
      json = JSON.parse(response.body)
      data = json['data']
      expect(data).to have_key('use_levels')
      expect(data).to have_key('item_types')
      expect(data).to have_key('talent_ids')
      expect(data['use_levels']).to be_an(Array)
    end
  end

  # ============================================
  # GET /api/explorer/items/:id/info
  # ============================================
  describe 'GET /api/explorer/items/:id/info' do
    it 'returns item info with translations' do
      get "/api/explorer/items/#{catalog_item.item_id}/info"
      expect(response).to have_http_status(:ok)
      json = JSON.parse(response.body)
      expect(json['data']).to be_present
    end

    it 'returns not found for non-existent item' do
      get '/api/explorer/items/999999/info'
      expect(response).to have_http_status(:not_found)
    end

    it 'filters advance extra fields using provider extension_fields whitelist' do
      provider = Metadata::Catalog::ProviderRegistry.current
      allow(Metadata::Catalog::ProviderRegistry).to receive(:current).and_return(provider)
      allow(provider).to receive(:capabilities).and_return(provider.capabilities.merge(extension_fields: %w[wealth_value]))

      get "/api/explorer/items/#{catalog_item.item_id}/info"

      expect(response).to have_http_status(:ok)
      json = JSON.parse(response.body)
      expect(json['data']['advance']['wealth_value']).to eq(100)
      expect(json['data']['advance']).not_to have_key('drop_scenes')
      expect(json['data']['base']['use_level']).to eq(3)
    end
  end

  # ============================================
  # GET /api/explorer/items/batch_info
  # ============================================
  describe 'GET /api/explorer/items/batch_info' do
    it 'returns batch item info for given ids' do
      get '/api/explorer/items/batch_info', params: { ids: catalog_item.item_id.to_s }
      expect(response).to have_http_status(:ok)
      json = JSON.parse(response.body)
      expect(json['data']).to be_an(Array)
    end

    it 'returns error when ids param is missing' do
      get '/api/explorer/items/batch_info', params: { ids: '' }
      expect(response).to have_http_status(:bad_request)
    end
  end

  # ============================================
  # GET /api/explorer/items/:id (show)
  # ============================================
  describe 'GET /api/explorer/items/:id' do
    it 'returns item from indexer with stats' do
      get "/api/explorer/items/#{indexer_item.id}"
      expect(response).to have_http_status(:ok)
      json = JSON.parse(response.body)
      data = json['data']
      expect(data['item']['id']).to eq(test_item_id.to_s)
      expect(data['stats']['source']).to eq('indexer')
      expect(data['stats']['instance_count']).to be_a(Integer)
    end

    it 'falls back to repo_sync when not in indexer' do
      catalog_only = create(:catalog_item, :with_translations, item_id: 80_999)
      get '/api/explorer/items/80999'
      expect(response).to have_http_status(:ok)
      json = JSON.parse(response.body)
      expect(json['data']['stats']['source']).to eq('repo_sync')
    end

    it 'returns not found when item does not exist anywhere' do
      get '/api/explorer/items/888888'
      expect(response).to have_http_status(:not_found)
    end

    it 'applies the advance whitelist to the item detail DTO' do
      provider = Metadata::Catalog::ProviderRegistry.current
      allow(Metadata::Catalog::ProviderRegistry).to receive(:current).and_return(provider)
      allow(provider).to receive(:capabilities).and_return(provider.capabilities.merge(extension_fields: %w[wealth_value]))

      get "/api/explorer/items/#{indexer_item.id}"

      expect(response).to have_http_status(:ok)
      json = JSON.parse(response.body)
      advance = json['data']['item']['item_info']['advance']

      expect(advance['wealth_value']).to eq(100)
      expect(advance).not_to have_key('drop_scenes')
      expect(json['data']['item']['item_info']['base']['use_level']).to eq(3)
    end
  end

  # ============================================
  # GET /api/explorer/items/:id/instances
  # ============================================
  describe 'GET /api/explorer/items/:id/instances' do
    it 'returns instances for the item' do
      get "/api/explorer/items/#{indexer_item.id}/instances"
      expect(response).to have_http_status(:ok)
      json = JSON.parse(response.body)
      expect(json['data']['instances']).to be_an(Array)
      expect(json['data']['item_id']).to eq(indexer_item.id)
      expect(json['data']['meta']).to have_key('total_count')
    end

    it 'returns not found for non-existent item' do
      get '/api/explorer/items/888888/instances'
      expect(response).to have_http_status(:not_found)
    end
  end

  # ============================================
  # GET /api/explorer/items/:id/holders
  # ============================================
  describe 'GET /api/explorer/items/:id/holders' do
    it 'returns holders with aggregated balances' do
      get "/api/explorer/items/#{indexer_item.id}/holders"
      expect(response).to have_http_status(:ok)
      json = JSON.parse(response.body)
      expect(json['data']['holders']).to be_an(Array)
      expect(json['data']['holders'].first).to have_key('address')
      expect(json['data']['holders'].first).to have_key('total_balance')
    end

    it 'returns not found for non-existent item' do
      get '/api/explorer/items/888888/holders'
      expect(response).to have_http_status(:not_found)
    end
  end
end
