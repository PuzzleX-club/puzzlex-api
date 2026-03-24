require 'rails_helper'

RSpec.describe Realtime::TopicParser, type: :service do
  describe '.parse_topic' do
    context 'when format is "MARKET@intvl"' do
      it 'parses MARKET@5 correctly' do
        topic = "MARKET@5"
        result = described_class.parse_topic(topic)
        expect(result).to eq({
                               market_id:  nil,
                               topic_type: "MARKET",
                               interval:   5
                             })
      end
    end

    context 'when format is "symbol@TICKER_intvl"' do
      it 'parses BTCUSDT@TICKER_1440' do
        topic = "BTCUSDT@TICKER_1440"
        result = described_class.parse_topic(topic)
        expect(result).to eq({
                               market_id:  "BTCUSDT",
                               topic_type: "TICKER",
                               interval:   1440
                             })
      end
    end

    context 'when format is "symbol@KLINE_intvl"' do
      it 'parses ETHUSDT@KLINE_60' do
        topic = "ETHUSDT@KLINE_60"
        result = described_class.parse_topic(topic)
        expect(result).to eq({
                               market_id:  "ETHUSDT",
                               topic_type: "KLINE",
                               interval:   60
                             })
      end
    end

    context 'when format is "symbol@DEPTH_intvl"' do
      it 'parses BTCUSDT@DEPTH_10' do
        topic = "BTCUSDT@DEPTH_10"
        result = described_class.parse_topic(topic)
        expect(result).to eq({
                               market_id:  "BTCUSDT",
                               topic_type: "DEPTH",
                               interval:   10
                             })
      end
    end

    context 'when format is "symbol@TRADE" (no interval)' do
      it 'parses BTCUSDT@TRADE' do
        topic = "BTCUSDT@TRADE"
        result = described_class.parse_topic(topic)
        expect(result).to eq({
                               market_id:  "BTCUSDT",
                               topic_type: "TRADE",
                               interval:   0
                             })
      end
    end

    context 'when invalid format' do
      it 'returns nil if cannot parse' do
        topic = "invalid_format"
        result = described_class.parse_topic(topic)
        expect(result).to be_nil
      end

      it 'returns nil if nothing after @' do
        topic = "BTCUSDT@"
        result = described_class.parse_topic(topic)
        expect(result).to be_nil
      end

      it 'returns nil if no @ found' do
        topic = "BTCUSDT_TICKER_1440" # missing '@'
        result = described_class.parse_topic(topic)
        expect(result).to be_nil
      end
    end
  end
end
