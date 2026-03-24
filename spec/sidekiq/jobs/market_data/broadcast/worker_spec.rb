# frozen_string_literal: true

require 'rails_helper'
require 'sidekiq/testing'

RSpec.describe Jobs::MarketData::Broadcast::Worker, type: :job do
  let(:worker) { described_class.new }

  before do
    Sidekiq::Testing.fake!
    allow(ActionCable.server).to receive(:broadcast)
  end

  after do
    Sidekiq::Testing.disable!
  end

  describe '#perform' do
    context 'with ticker_batch broadcast' do
      let(:params) { { 'topic' => '@TICKER_1440' } }
      let(:mock_strategy) do
        double('TickerBatchStrategy', execute: {
          success: true,
          stats: { type: 'ticker_batch', success: 2, failed: 0, skipped: 0, total: 2 }
        })
      end

      before do
        allow_any_instance_of(described_class).to receive(:get_strategy)
          .with('ticker_batch').and_return(mock_strategy)
      end

      it 'broadcasts ticker data' do
        expect(mock_strategy).to receive(:execute).with(params)
        worker.perform('ticker_batch', params)
      end

      it 'returns result from strategy' do
        result = worker.perform('ticker_batch', params)
        expect(result[:success]).to eq(true)
      end
    end

    context 'with kline_batch broadcast' do
      let(:params) do
        {
          'batch' => [
            { 'topic' => '2800@KLINE_30', 'timestamp' => Time.current.to_i, 'market_id' => '2800', 'interval_minutes' => 30, 'is_realtime' => true }
          ]
        }
      end
      let(:mock_strategy) do
        double('KlineBatchStrategy')
      end

      before do
        allow_any_instance_of(described_class).to receive(:get_strategy)
          .with('kline_batch').and_return(mock_strategy)
      end

      it 'broadcasts kline data with dual window' do
        expect(mock_strategy).to receive(:execute)
          .with(params)
          .and_return({ success: true, stats: { type: 'kline_batch', success: 1, failed: 0, skipped: 0, total: 1 } })
        worker.perform('kline_batch', params)
      end

      it 'executes without error for the batch' do
        allow(mock_strategy).to receive(:execute)
          .and_return({ success: true, stats: { type: 'kline_batch', success: 1, failed: 0, skipped: 0, total: 1 } })
        result = worker.perform('kline_batch', params)
        expect(result[:stats][:success]).to be >= 0
      end
    end

    context 'with depth broadcast' do
      let(:params) { { 'market_id' => '2800', 'limit' => 20 } }
      let(:mock_strategy) do
        double('DepthStrategy')
      end

      before do
        allow_any_instance_of(described_class).to receive(:get_strategy)
          .with('depth').and_return(mock_strategy)
      end

      it 'broadcasts depth data' do
        expect(mock_strategy).to receive(:execute)
          .with(params)
          .and_return({ success: true, stats: { type: 'depth', success: 1, failed: 0, skipped: 0, total: 1 } })
        worker.perform('depth', params)
      end

      it 'handles heartbeat mode' do
        params['is_heartbeat'] = true
        expect(mock_strategy).to receive(:execute)
          .with(params)
          .and_return({ success: true, stats: { type: 'depth_heartbeat', success: 1, failed: 0, skipped: 0, total: 1 } })
        worker.perform('depth', params)
      end
    end

    context 'with market_realtime broadcast' do
      let(:params) { { 'topic' => 'MARKET@realtime' } }
      let(:mock_strategy) do
        double('MarketRealtimeStrategy')
      end

      before do
        allow_any_instance_of(described_class).to receive(:get_strategy)
          .with('market_realtime').and_return(mock_strategy)
      end

      it 'broadcasts market realtime data' do
        expect(mock_strategy).to receive(:execute)
          .with(params)
          .and_return({ success: true, stats: { type: 'market_realtime', success: 1, failed: 0, skipped: 0, total: 1 } })
        worker.perform('market_realtime', params)
      end
    end

    context 'with unsupported broadcast type' do
      it 'raises ArgumentError' do
        expect { worker.perform('invalid_type', {}) }
          .to raise_error(ArgumentError, /Unsupported broadcast type/)
      end
    end
  end

  describe 'job configuration' do
    it 'uses the correct queue' do
      expect(described_class.get_sidekiq_options['queue'].to_s).to eq('broadcast')
    end

    it 'has retry set to 3' do
      expect(described_class.get_sidekiq_options['retry']).to eq(3)
    end
  end

  describe 'broadcast types constant' do
    it 'includes all supported broadcast types' do
      expected_types = %w[ticker_batch kline_batch depth market_realtime]
      expect(described_class::BROADCAST_TYPES.keys).to include(*expected_types)
    end
  end
end
