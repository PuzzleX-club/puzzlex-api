# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Trading::TradesController', type: :request do
  let(:user_address) { '0x' + SecureRandom.hex(20) }
  let(:user) { create(:accounts_user, address: user_address) }
  let(:auth_token) { generate_jwt_for(user) }
  let(:headers) do
    {
      'Authorization' => "Bearer #{auth_token}",
      'Content-Type' => 'application/json'
    }
  end

  before do
    allow(MarketData::PriceCalculator).to receive(:calculate_price_from_fill).and_return(1_000_000)
  end

  # ============================================
  # GET /api/market/trading/trades/history
  # ============================================
  describe 'GET /api/market/trading/trades/history' do
    context 'public access (user_filter=all)' do
      it 'returns 200 with trades array' do
        get '/api/market/trading/trades/history',
            params: { market_id: '2800', limit: 10 }

        expect(response).to have_http_status(:ok)
        json = JSON.parse(response.body)
        expect(json['code']).to eq(200)
        expect(json['data']['trades']).to be_an(Array)
        expect(json['data']['pagination']).to include('limit', 'has_more')
      end
    end

    context 'user-filtered access without auth' do
      it 'returns 401 for my_trades without auth' do
        get '/api/market/trading/trades/history',
            params: { market_id: '2800', user_filter: 'my_trades' }

        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'user-filtered access with auth' do
      let!(:order) { create(:trading_order, offerer: user_address) }
      let!(:fill) do
        create(:trading_order_fill,
               order: order,
               market_id: 2800,
               buyer_address: user_address,
               seller_address: '0x' + SecureRandom.hex(20))
      end

      it 'returns 200 with user trades' do
        get '/api/market/trading/trades/history',
            params: { market_id: '2800', user_filter: 'my_trades' },
            headers: headers

        expect(response).to have_http_status(:ok)
        json = JSON.parse(response.body)
        expect(json['code']).to eq(200)
        expect(json['data']['trades']).to be_an(Array)
      end
    end

    context 'with pagination' do
      it 'respects limit parameter (clamped to 10..100)' do
        get '/api/market/trading/trades/history',
            params: { market_id: '2800', limit: 50 }

        expect(response).to have_http_status(:ok)
        json = JSON.parse(response.body)
        expect(json['data']['pagination']['limit']).to eq(50)
      end
    end

    context 'with order_type filter' do
      it 'filters by order direction' do
        get '/api/market/trading/trades/history',
            params: { market_id: '2800', order_type: 'List' }

        expect(response).to have_http_status(:ok)
      end
    end
  end

  # ============================================
  # GET /api/market/trading/trades/statistics
  # ============================================
  describe 'GET /api/market/trading/trades/statistics' do
    context 'public access' do
      it 'returns 200 with statistics shape' do
        get '/api/market/trading/trades/statistics',
            params: { market_id: '2800' }

        expect(response).to have_http_status(:ok)
        json = JSON.parse(response.body)
        expect(json['code']).to eq(200)
        stats = json['data']
        expect(stats).to include('total_trades', 'total_volume', 'total_value')
        expect(stats).to include('buy_trades', 'sell_trades', 'recent_activity')
      end
    end

    context 'user-filtered without auth' do
      it 'returns 401 for my_trades' do
        get '/api/market/trading/trades/statistics',
            params: { market_id: '2800', user_filter: 'my_trades' }

        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'user-filtered with auth' do
      it 'returns 200 with buy/sell breakdown' do
        get '/api/market/trading/trades/statistics',
            params: { market_id: '2800', user_filter: 'my_trades' },
            headers: headers

        expect(response).to have_http_status(:ok)
        json = JSON.parse(response.body)
        expect(json['data']['buy_trades']).to include('count', 'volume', 'value')
        expect(json['data']['sell_trades']).to include('count', 'volume', 'value')
      end
    end
  end

  # ============================================
  # GET /api/market/trading/trades/:trade_hash
  # ============================================
  describe 'GET /api/market/trading/trades/:trade_hash' do
    context 'without authentication' do
      it 'returns 401' do
        get '/api/market/trading/trades/0x1234'

        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'with authentication' do
      context 'when trade does not exist' do
        it 'returns 404' do
          get '/api/market/trading/trades/0xnonexistent', headers: headers

          expect(response).to have_http_status(:not_found)
        end
      end

      context 'when trade exists' do
        let!(:order) { create(:trading_order, offerer: user_address) }
        let!(:fill) do
          create(:trading_order_fill,
                 order: order,
                 transaction_hash: '0xabc123',
                 buyer_address: user_address,
                 seller_address: '0x' + SecureRandom.hex(20))
        end

        it 'returns 200 with trade detail' do
          get "/api/market/trading/trades/#{fill.transaction_hash}", headers: headers

          expect(response).to have_http_status(:ok)
          json = JSON.parse(response.body)
          expect(json['code']).to eq(200)
          expect(json['data']).to include('trade_hash', 'market_id')
        end
      end
    end
  end

  # ============================================
  # GET /api/market/trading/trades/export
  # ============================================
  describe 'GET /api/market/trading/trades/export' do
    context 'without authentication' do
      it 'returns 401' do
        get '/api/market/trading/trades/export'

        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'with user_filter=all' do
      it 'returns 400 because export only supports personal records' do
        get '/api/market/trading/trades/export',
            params: { user_filter: 'all' },
            headers: headers

        expect(response).to have_http_status(:bad_request)
      end
    end

    context 'with valid user_filter' do
      it 'returns 200 with export data' do
        get '/api/market/trading/trades/export',
            params: { user_filter: 'my_trades' },
            headers: headers

        expect(response).to have_http_status(:ok)
        json = JSON.parse(response.body)
        expect(json['code']).to eq(200)
        expect(json['data']['trades']).to be_an(Array)
        expect(json['data']['export_info']).to include('total_records', 'export_date')
      end
    end
  end
end
