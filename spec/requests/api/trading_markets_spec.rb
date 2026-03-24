# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Trading::MarketsController', type: :request do
  let(:user_address) { '0x' + SecureRandom.hex(20) }
  let(:user) { create(:accounts_user, address: user_address) }
  let(:auth_token) { generate_jwt_for(user) }
  let(:headers) do
    {
      'Authorization' => "Bearer #{auth_token}",
      'Content-Type' => 'application/json'
    }
  end

  # ============================================
  # GET /api/market/trading/markets/:id/summary
  # ============================================
  describe 'GET /api/market/trading/markets/:id/summary' do
    context 'with invalid market_id' do
      it 'returns 400 for non-positive id' do
        get '/api/market/trading/markets/0/summary', headers: headers

        expect(response).to have_http_status(:bad_request)
        json = JSON.parse(response.body)
        expect(json['message']).to match(/Invalid market_id/i)
      end

      it 'returns 400 for non-numeric id' do
        get '/api/market/trading/markets/abc/summary', headers: headers

        expect(response).to have_http_status(:bad_request)
      end
    end

    context 'when market does not exist' do
      before do
        allow(MarketData::MarketSummaryService).to receive(:new).and_return(
          double(call: {})
        )
        allow(MarketData::MarketSummaryStore).to receive(:upsert_summary)
        allow(RuntimeCache::MarketDataStore).to receive(:store_market_summary) if defined?(RuntimeCache::MarketDataStore)
      end

      it 'returns 404 when summary record is nil after refresh' do
        get '/api/market/trading/markets/99999/summary', headers: headers

        expect(response).to have_http_status(:not_found)
        json = JSON.parse(response.body)
        expect(json['message']).to match(/not found/i)
      end
    end

    context 'when market summary exists' do
      let!(:summary_record) do
        Trading::MarketSummary.create!(
          market_id: '2800',
          dirty: false
        )
      end

      before do
        allow(MarketData::MarketSummaryStore).to receive(:serialize)
          .with(summary_record)
          .and_return({ market_id: '2800', last_price: '1000' })
      end

      it 'returns 200 with serialized summary' do
        get '/api/market/trading/markets/2800/summary', headers: headers

        expect(response).to have_http_status(:ok)
        json = JSON.parse(response.body)
        expect(json['code']).to eq(200)
        expect(json['data']).to include('market_id' => '2800')
      end
    end
  end

  # ============================================
  # GET /api/market/trading/markets/summary_list
  # ============================================
  describe 'GET /api/market/trading/markets/summary_list' do
    context 'with missing parameters' do
      it 'returns 400 when neither ids nor pagination provided' do
        get '/api/market/trading/markets/summary_list', headers: headers

        expect(response).to have_http_status(:bad_request)
        json = JSON.parse(response.body)
        expect(json['message']).to match(/Missing ids or pagination/i)
      end
    end

    context 'with invalid ids parameter' do
      it 'returns 400 for blank ids' do
        get '/api/market/trading/markets/summary_list',
            params: { ids: '' },
            headers: headers

        expect(response).to have_http_status(:bad_request)
      end
    end

    context 'with valid ids parameter' do
      let!(:summary_2800) do
        Trading::MarketSummary.create!(market_id: '2800', dirty: false)
      end

      before do
        allow(MarketData::MarketSummaryStore).to receive(:fetch_summaries)
          .and_return({ '2800' => summary_2800 })
        allow(MarketData::MarketSummaryStore).to receive(:serialize)
          .with(summary_2800)
          .and_return({ market_id: '2800', last_price: '1000' })
      end

      it 'returns 200 with markets array' do
        get '/api/market/trading/markets/summary_list',
            params: { ids: '2800' },
            headers: headers

        expect(response).to have_http_status(:ok)
        json = JSON.parse(response.body)
        expect(json['code']).to eq(200)
        expect(json['data']['markets']).to be_an(Array)
        expect(json['data']['ids']).to be_an(Array)
      end
    end

    context 'with pagination parameters' do
      before do
        allow(MarketData::MarketSummaryStore).to receive(:fetch_summaries)
          .and_return({})
        allow(MarketData::MarketSummaryStore).to receive(:total_count).and_return(0)
        allow(MarketData::MarketSummaryStore).to receive(:fetch_page).and_return([])
      end

      it 'returns 200 with empty markets and pagination' do
        get '/api/market/trading/markets/summary_list',
            params: { page: 1, per: 10 },
            headers: headers

        expect(response).to have_http_status(:ok)
        json = JSON.parse(response.body)
        expect(json['data']['markets']).to eq([])
        expect(json['data']['pagination']).to include('page' => 1, 'per' => 10)
      end
    end
  end
end
