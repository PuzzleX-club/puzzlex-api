# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Explorer Transfers API', type: :request do
  let!(:indexer_item) { create(:indexer_item, id: '32') }
  let!(:indexer_instance) do
    create(:indexer_instance, id: 'token-32-01',
           item_record: indexer_item, item: '32')
  end
  let(:sender) { '0x' + 'e5' * 20 }
  let(:receiver) { '0x' + 'f6' * 20 }
  let(:zero_addr) { '0x0000000000000000000000000000000000000000' }
  let(:now_ts) { Time.current.to_i }

  let!(:mint_tx) do
    create(:indexer_transaction,
           id: "0x#{SecureRandom.hex(32)}-0-1",
           item_record: indexer_item,
           instance_record: indexer_instance,
           item: indexer_item.id,
           instance: indexer_instance.id,
           from_address: zero_addr,
           to_address: receiver,
           amount: 10,
           timestamp: now_ts - 3600)
  end
  let!(:transfer_tx) do
    create(:indexer_transaction,
           id: "0x#{SecureRandom.hex(32)}-0-2",
           item_record: indexer_item,
           instance_record: indexer_instance,
           item: indexer_item.id,
           instance: indexer_instance.id,
           from_address: receiver,
           to_address: sender,
           amount: 5,
           timestamp: now_ts - 1800)
  end
  let!(:burn_tx) do
    create(:indexer_transaction,
           id: "0x#{SecureRandom.hex(32)}-0-3",
           item_record: indexer_item,
           instance_record: indexer_instance,
           item: indexer_item.id,
           instance: indexer_instance.id,
           from_address: sender,
           to_address: zero_addr,
           amount: 2,
           timestamp: now_ts)
  end

  # ============================================
  # GET /api/explorer/transfers
  # ============================================
  describe 'GET /api/explorer/transfers' do
    it 'returns all transfers with pagination' do
      get '/api/explorer/transfers'
      expect(response).to have_http_status(:ok)
      json = JSON.parse(response.body)
      expect(json['data']['transfers']).to be_an(Array)
      expect(json['data']['transfers'].length).to be >= 3
      expect(json['data']['meta']['total_count']).to be >= 3
    end

    it 'filters by item_id' do
      get '/api/explorer/transfers', params: { item_id: '32' }
      json = JSON.parse(response.body)
      expect(json['data']['transfers'].length).to eq(3)
    end

    it 'filters by instance_id' do
      get '/api/explorer/transfers', params: { instance_id: indexer_instance.id }
      json = JSON.parse(response.body)
      expect(json['data']['transfers'].length).to eq(3)
    end

    it 'filters by address (from or to)' do
      get '/api/explorer/transfers', params: { address: receiver }
      json = JSON.parse(response.body)
      # receiver appears in mint (to) and transfer (from)
      expect(json['data']['transfers'].length).to eq(2)
    end

    it 'filters by type=mint' do
      get '/api/explorer/transfers', params: { type: 'mint', instance_id: indexer_instance.id }
      json = JSON.parse(response.body)
      transfers = json['data']['transfers']
      expect(transfers.length).to eq(1)
      expect(transfers.first['type']).to eq('mint')
    end

    it 'filters by type=burn' do
      get '/api/explorer/transfers', params: { type: 'burn', instance_id: indexer_instance.id }
      json = JSON.parse(response.body)
      transfers = json['data']['transfers']
      expect(transfers.length).to eq(1)
      expect(transfers.first['type']).to eq('burn')
    end

    it 'filters by type=transfer' do
      get '/api/explorer/transfers', params: { type: 'transfer', instance_id: indexer_instance.id }
      json = JSON.parse(response.body)
      transfers = json['data']['transfers']
      expect(transfers.length).to eq(1)
      expect(transfers.first['type']).to eq('transfer')
    end

    it 'filters by time range' do
      get '/api/explorer/transfers', params: {
        instance_id: indexer_instance.id,
        start_time: now_ts - 2000,
        end_time: now_ts + 100
      }
      json = JSON.parse(response.body)
      # transfer_tx (now-1800) and burn_tx (now) fall in range
      expect(json['data']['transfers'].length).to eq(2)
    end

    it 'supports pagination' do
      get '/api/explorer/transfers', params: { instance_id: indexer_instance.id, page: 1, per_page: 2 }
      json = JSON.parse(response.body)
      expect(json['data']['transfers'].length).to eq(2)
      expect(json['data']['meta']['has_more']).to be true
    end
  end

  # ============================================
  # GET /api/explorer/transfers/:id
  # ============================================
  describe 'GET /api/explorer/transfers/:id' do
    it 'returns transfer detail' do
      get "/api/explorer/transfers/#{mint_tx.id}"
      expect(response).to have_http_status(:ok)
      json = JSON.parse(response.body)
      data = json['data']['transfer']
      expect(data['id']).to eq(mint_tx.id)
      expect(data['type']).to eq('mint')
      expect(data).to have_key('transaction_hash')
      expect(data).to have_key('block_number')
      expect(data).to have_key('amount')
    end

    it 'returns not found for non-existent transfer' do
      get '/api/explorer/transfers/nonexistent-tx-id'
      expect(response).to have_http_status(:not_found)
    end
  end
end
