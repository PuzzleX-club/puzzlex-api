# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Explorer Players API', type: :request do
  let(:player_address) { '0x' + 'c3' * 20 }
  let!(:indexer_item) { create(:indexer_item, id: '31') }
  let!(:indexer_instance) do
    create(:indexer_instance, id: 'token-31-01',
           item_record: indexer_item, item: '31')
  end
  let!(:player) { create(:indexer_player, id: player_address) }
  let!(:balance) do
    create(:indexer_instance_balance,
           id: "#{indexer_instance.id}-#{player.id}",
           instance_record: indexer_instance,
           player_record: player,
           instance: indexer_instance.id,
           player: player.id,
           balance: 15,
           minted_amount: 15)
  end
  let!(:mint_tx) do
    create(:indexer_transaction, :mint,
           id: "0x#{SecureRandom.hex(32)}-0-1",
           item_record: indexer_item,
           instance_record: indexer_instance,
           item: indexer_item.id,
           instance: indexer_instance.id,
           to_address: player_address,
           amount: 15)
  end
  let!(:transfer_tx) do
    create(:indexer_transaction, :transfer,
           id: "0x#{SecureRandom.hex(32)}-0-2",
           item_record: indexer_item,
           instance_record: indexer_instance,
           item: indexer_item.id,
           instance: indexer_instance.id,
           from_address: player_address,
           to_address: '0x' + 'dd' * 20,
           amount: 3)
  end

  # ============================================
  # GET /api/explorer/players
  # ============================================
  describe 'GET /api/explorer/players' do
    it 'returns players aggregated by balance' do
      get '/api/explorer/players'
      expect(response).to have_http_status(:ok)
      json = JSON.parse(response.body)
      expect(json['data']['players']).to be_an(Array)
      expect(json['data']['players'].length).to be >= 1
      first = json['data']['players'].first
      expect(first).to have_key('address')
      expect(first).to have_key('total_balance')
      expect(first).to have_key('unique_items_count')
    end

    it 'returns pagination metadata' do
      get '/api/explorer/players', params: { page: 1, per_page: 5 }
      json = JSON.parse(response.body)
      expect(json['data']['meta']).to have_key('current_page')
      expect(json['data']['meta']).to have_key('total_count')
    end
  end

  # ============================================
  # GET /api/explorer/players/:address
  # ============================================
  describe 'GET /api/explorer/players/:address' do
    it 'returns player details' do
      get "/api/explorer/players/#{player_address}"
      expect(response).to have_http_status(:ok)
      json = JSON.parse(response.body)
      data = json['data']['player']
      expect(data['address']).to eq(player_address)
      expect(data['total_balance_count']).to eq(1)
      expect(data['unique_items_count']).to be_a(Integer)
      expect(data).to have_key('first_seen')
      expect(data).to have_key('last_active')
    end

    it 'handles case-insensitive address lookup' do
      get "/api/explorer/players/#{player_address.upcase}"
      expect(response).to have_http_status(:ok)
    end

    it 'returns not found for non-existent player' do
      get '/api/explorer/players/0xdeaddeaddeaddeaddeaddeaddeaddeaddeaddead'
      expect(response).to have_http_status(:not_found)
    end
  end

  # ============================================
  # GET /api/explorer/players/:address/balances
  # ============================================
  describe 'GET /api/explorer/players/:address/balances' do
    it 'returns player NFT balances' do
      get "/api/explorer/players/#{player_address}/balances"
      expect(response).to have_http_status(:ok)
      json = JSON.parse(response.body)
      data = json['data']
      expect(data['player']).to eq(player_address)
      expect(data['balances']).to be_an(Array)
      expect(data['balances'].length).to eq(1)
      bal = data['balances'].first
      expect(bal['instance_id']).to eq(indexer_instance.id)
      expect(bal['balance']).to eq('15')
      expect(data['meta']).to have_key('total_count')
    end

    it 'returns not found for non-existent player' do
      get '/api/explorer/players/0xdeaddeaddeaddeaddeaddeaddeaddeaddeaddead/balances'
      expect(response).to have_http_status(:not_found)
    end
  end

  # ============================================
  # GET /api/explorer/players/:address/transfers
  # ============================================
  describe 'GET /api/explorer/players/:address/transfers' do
    it 'returns player transfer history' do
      get "/api/explorer/players/#{player_address}/transfers"
      expect(response).to have_http_status(:ok)
      json = JSON.parse(response.body)
      data = json['data']
      expect(data['player']).to eq(player_address)
      expect(data['transfers']).to be_an(Array)
      expect(data['transfers'].length).to eq(2) # mint + transfer
    end

    it 'filters by type=mint' do
      get "/api/explorer/players/#{player_address}/transfers", params: { type: 'mint' }
      json = JSON.parse(response.body)
      transfers = json['data']['transfers']
      expect(transfers.length).to eq(1)
      expect(transfers.first['type']).to eq('mint')
    end

    it 'filters by type=transfer' do
      get "/api/explorer/players/#{player_address}/transfers", params: { type: 'transfer' }
      json = JSON.parse(response.body)
      transfers = json['data']['transfers']
      expect(transfers.length).to eq(1)
      expect(transfers.first['type']).to eq('transfer')
    end

    it 'returns not found for non-existent player' do
      get '/api/explorer/players/0xdeaddeaddeaddeaddeaddeaddeaddeaddeaddead/transfers'
      expect(response).to have_http_status(:not_found)
    end
  end
end
