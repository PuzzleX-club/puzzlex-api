# spec/requests/klines_spec.rb
require 'rails_helper'

RSpec.describe "Klines API", type: :request do
  describe "GET /api/market/klines" do
    before do
      @custom_market = create(:market, item_id: 123)
      @other_market = create(:market, item_id: 199)
    end

    let(:interval)  { 60 }
    let(:start_ts)  { 1650000000 }
    let(:end_ts)    { 1650000300 }

    before do
      create(:trading_kline, market: @custom_market, interval: interval, timestamp: 1650000000, open: 100, high: 120, low: 90, close: 110, volume: 10, turnover: 1000)
      create(:trading_kline, market: @custom_market, interval: interval, timestamp: 1650000060, open: 110, high: 130, low: 100, close: 120, volume: 20, turnover: 2400)
      # Other market / same interval - should not be returned
      create(:trading_kline, market: @other_market, interval: interval, timestamp: 1650000060)
    end

    it "returns kline data within [start_ts, end_ts]" do
      get '/api/market/klines', params: {
        market_id: @custom_market.market_id,
        intvl: interval,
        start_ts: start_ts,
        end_ts: end_ts
      }

      expect(response).to have_http_status(:ok)

      json_body = JSON.parse(response.body)
      expect(json_body["code"]).to eq(0)

      klines_array = json_body["data"]
      expect(klines_array.size).to eq(2)

      # Controller returns objects with ts/open/high/low/close/vol/tor keys
      # and orders by timestamp desc, so the first entry is the later timestamp
      first_kline = klines_array[0]
      second_kline = klines_array[1]

      expect(first_kline["ts"].to_f).to eq(1650000060)
      expect(first_kline["open"].to_f).to eq(110)
      expect(first_kline["high"].to_f).to eq(130)

      expect(second_kline["ts"].to_f).to eq(1650000000)
      expect(second_kline["open"].to_f).to eq(100)
      expect(second_kline["high"].to_f).to eq(120)
    end
  end
end
