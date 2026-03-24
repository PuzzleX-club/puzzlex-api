# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Explorer Instances API', type: :request do
  let!(:indexer_item) { create(:indexer_item, id: '30') }
  let!(:indexer_instance) do
    create(:indexer_instance, id: 'token-30-01',
           item_record: indexer_item, item: '30',
           quality: '0x01', metadata_status: 'completed')
  end
  let!(:metadata) do
    create(:indexer_metadata,
           instance_id: indexer_instance.id,
           item_id: indexer_item.id,
           name: 'Rare Gem',
           description: 'A sparkling gem',
           image: 'https://example.com/gem.png')
  end
  let!(:attr_quality) do
    create(:indexer_attribute,
           instance_id: indexer_instance.id,
           item_id: indexer_item.id,
           trait_type: 'Quality',
           value_string: '5')
  end
  let!(:player) { create(:indexer_player, id: '0x' + 'b2' * 20) }
  let!(:balance) do
    create(:indexer_instance_balance,
           id: "#{indexer_instance.id}-#{player.id}",
           instance_record: indexer_instance,
           player_record: player,
           instance: indexer_instance.id,
           player: player.id,
           balance: 10,
           minted_amount: 10)
  end
  let!(:transfer) do
    create(:indexer_transaction, :mint,
           id: "0x#{SecureRandom.hex(32)}-0-1",
           item_record: indexer_item,
           instance_record: indexer_instance,
           item: indexer_item.id,
           instance: indexer_instance.id,
           to_address: player.id,
           amount: 10)
  end

  # ============================================
  # GET /api/explorer/instances
  # ============================================
  describe 'GET /api/explorer/instances' do
    it 'returns instances with pagination' do
      get '/api/explorer/instances'
      expect(response).to have_http_status(:ok)
      json = JSON.parse(response.body)
      expect(json['data']['instances']).to be_an(Array)
      expect(json['data']['instances'].length).to be >= 1
      expect(json['data']['meta']['total_count']).to be >= 1
    end

    it 'filters by item_id' do
      get '/api/explorer/instances', params: { item_id: '30' }
      json = JSON.parse(response.body)
      expect(json['data']['instances'].length).to eq(1)
    end

    it 'returns empty for non-matching item_id filter' do
      get '/api/explorer/instances', params: { item_id: '999' }
      json = JSON.parse(response.body)
      expect(json['data']['instances']).to be_empty
    end

    it 'supports pagination parameters' do
      get '/api/explorer/instances', params: { page: 1, per_page: 10 }
      json = JSON.parse(response.body)
      expect(json['data']['meta']['per_page']).to eq(10)
    end
  end

  # ============================================
  # GET /api/explorer/instances/:id
  # ============================================
  describe 'GET /api/explorer/instances/:id' do
    it 'returns instance with metadata and attributes' do
      get "/api/explorer/instances/#{indexer_instance.id}"
      expect(response).to have_http_status(:ok)
      json = JSON.parse(response.body)
      data = json['data']
      expect(data['instance']['id']).to eq(indexer_instance.id)
      expect(data['instance']['metadata']).to be_present
      expect(data['instance']['metadata']['name']).to eq('Rare Gem')
      expect(data['attributes']).to be_an(Array)
      expect(data['stats']['holder_count']).to eq(1)
    end

    it 'returns not found for non-existent instance' do
      get '/api/explorer/instances/nonexistent-token'
      expect(response).to have_http_status(:not_found)
    end
  end

  # ============================================
  # GET /api/explorer/instances/:id/balances
  # ============================================
  describe 'GET /api/explorer/instances/:id/balances' do
    it 'returns holder balances for the instance' do
      get "/api/explorer/instances/#{indexer_instance.id}/balances"
      expect(response).to have_http_status(:ok)
      json = JSON.parse(response.body)
      data = json['data']
      expect(data['instance_id']).to eq(indexer_instance.id)
      expect(data['balances']).to be_an(Array)
      expect(data['balances'].first['player']).to eq(player.id)
      expect(data['balances'].first['balance']).to eq('10')
      expect(data['meta']).to have_key('total_count')
    end

    it 'returns not found for non-existent instance' do
      get '/api/explorer/instances/nonexistent/balances'
      expect(response).to have_http_status(:not_found)
    end
  end

  # ============================================
  # GET /api/explorer/instances/:id/transfers
  # ============================================
  describe 'GET /api/explorer/instances/:id/transfers' do
    it 'returns transfer history for the instance' do
      get "/api/explorer/instances/#{indexer_instance.id}/transfers"
      expect(response).to have_http_status(:ok)
      json = JSON.parse(response.body)
      data = json['data']
      expect(data['instance_id']).to eq(indexer_instance.id)
      expect(data['transfers']).to be_an(Array)
      expect(data['transfers'].length).to eq(1)
    end

    it 'filters by type=mint' do
      get "/api/explorer/instances/#{indexer_instance.id}/transfers", params: { type: 'mint' }
      json = JSON.parse(response.body)
      expect(json['data']['transfers'].length).to eq(1)
      expect(json['data']['transfers'].first['type']).to eq('mint')
    end

    it 'filters by type=burn (none expected)' do
      get "/api/explorer/instances/#{indexer_instance.id}/transfers", params: { type: 'burn' }
      json = JSON.parse(response.body)
      expect(json['data']['transfers']).to be_empty
    end

    it 'filters by type=transfer (none expected)' do
      get "/api/explorer/instances/#{indexer_instance.id}/transfers", params: { type: 'transfer' }
      json = JSON.parse(response.body)
      expect(json['data']['transfers']).to be_empty
    end

    it 'returns not found for non-existent instance' do
      get '/api/explorer/instances/nonexistent/transfers'
      expect(response).to have_http_status(:not_found)
    end
  end
end
