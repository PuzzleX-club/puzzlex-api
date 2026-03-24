# frozen_string_literal: true

require 'rails_helper'
require 'sidekiq/testing'

RSpec.describe Jobs::MarketData::Broadcast::DispatcherJob, type: :job do
  let(:worker) { described_class.new }

  before do
    Sidekiq::Testing.fake!
    allow(ActionCable.server).to receive(:broadcast)
    # Mock ElectionService
    allow(Sidekiq::Election::Service).to receive(:leader?).and_return(true)
    # Mock Throttleable concern
    allow_any_instance_of(described_class).to receive(:should_throttle?).and_return(false)
  end

  after do
    Sidekiq::Testing.disable!
  end

  describe '#perform' do
    context 'when leader' do
      before do
        # Mock scheduling strategies
        mock_strategy = double('Strategy', get_pending_tasks: [])
        allow(Strategies::KlineSchedulingStrategy).to receive(:new).and_return(mock_strategy)
        allow(Strategies::TickerSchedulingStrategy).to receive(:new).and_return(mock_strategy)
        allow(Strategies::MarketSchedulingStrategy).to receive(:new).and_return(mock_strategy)
        allow(Strategies::DepthSchedulingStrategy).to receive(:new).and_return(mock_strategy)
        # Mock InstanceRegistry
        allow(Sidekiq::Cluster::InstanceRegistry).to receive(:get_active_instances).and_return([])
        # Mock orphan queue check (skip it)
        allow_any_instance_of(described_class).to receive(:check_orphan_queues_if_needed)
        # Mock ensure_initialization (skip it by pretending already initialized)
        allow_any_instance_of(described_class).to receive(:ensure_initialization)
      end

      it 'executes scheduling cycle' do
        expect { worker.perform }.not_to raise_error
      end

      it 'dispatches market update tasks' do
        kline_strategy = double('KlineStrategy', get_pending_tasks: [
          { type: 'market_update', params: { topic: 'MARKET@1440' } }
        ])
        allow(Strategies::KlineSchedulingStrategy).to receive(:new).and_return(kline_strategy)

        mock_strategy = double('Strategy', get_pending_tasks: [])
        allow(Strategies::TickerSchedulingStrategy).to receive(:new).and_return(mock_strategy)
        allow(Strategies::MarketSchedulingStrategy).to receive(:new).and_return(mock_strategy)
        allow(Strategies::DepthSchedulingStrategy).to receive(:new).and_return(mock_strategy)

        expect(Jobs::MarketData::MarketUpdateJob).to receive(:perform_async)
        worker.perform
      end

      it 'dispatches broadcast tasks to Worker' do
        depth_strategy = double('DepthStrategy', get_pending_tasks: [
          { type: 'depth', params: { market_id: '2800' } }
        ])
        allow(Strategies::DepthSchedulingStrategy).to receive(:new).and_return(depth_strategy)

        mock_strategy = double('Strategy', get_pending_tasks: [])
        allow(Strategies::KlineSchedulingStrategy).to receive(:new).and_return(mock_strategy)
        allow(Strategies::TickerSchedulingStrategy).to receive(:new).and_return(mock_strategy)
        allow(Strategies::MarketSchedulingStrategy).to receive(:new).and_return(mock_strategy)

        expect(Jobs::MarketData::Broadcast::Worker).to receive(:perform_async)
          .with('depth', { market_id: '2800' })
        worker.perform
      end
    end

    context 'when not leader' do
      before do
        allow(Sidekiq::Election::Service).to receive(:leader?).and_return(false)
      end

      it 'skips scheduling' do
        expect(Strategies::KlineSchedulingStrategy).not_to receive(:new)
        worker.perform
      end
    end

    context 'with election service error' do
      before do
        allow(Sidekiq::Election::Service).to receive(:leader?).and_raise(StandardError, 'Election error')
      end

      it 'handles error gracefully' do
        expect { worker.perform }.not_to raise_error
      end
    end
  end

  describe 'initialization' do
    it 'ensures initialization on first run' do
      # Mock ensure_initialization to actually call through
      allow_any_instance_of(described_class).to receive(:check_orphan_queues_if_needed)

      mock_strategy = double('Strategy', get_pending_tasks: [])
      allow(Strategies::KlineSchedulingStrategy).to receive(:new).and_return(mock_strategy)
      allow(Strategies::TickerSchedulingStrategy).to receive(:new).and_return(mock_strategy)
      allow(Strategies::MarketSchedulingStrategy).to receive(:new).and_return(mock_strategy)
      allow(Strategies::DepthSchedulingStrategy).to receive(:new).and_return(mock_strategy)
      allow(Sidekiq::Cluster::InstanceRegistry).to receive(:get_active_instances).and_return([])

      # Sidekiq.redis yields mock_redis which returns nil for get (first run)
      expect(Jobs::MarketData::MarketUpdateJob).to receive(:perform_sync)
      worker.perform
    end
  end

  describe 'job configuration' do
    it 'uses the correct queue' do
      expect(described_class.get_sidekiq_options['queue'].to_s).to eq('scheduler')
    end

    it 'has retry set to 2' do
      expect(described_class.get_sidekiq_options['retry']).to eq(2)
    end
  end
end
