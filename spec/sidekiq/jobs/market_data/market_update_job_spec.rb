# frozen_string_literal: true

require 'rails_helper'
require 'sidekiq/testing'

RSpec.describe Jobs::MarketData::MarketUpdateJob, type: :job do
  let(:worker) { described_class.new }

  before do
    Sidekiq::Testing.fake!
    # Stub at_exit to avoid side effects in tests
    allow_any_instance_of(described_class).to receive(:at_exit)
    # Stub runtime cache services
    allow(::RuntimeCache::MarketDataStore).to receive(:update_market_summary).and_return(true)
    allow(::RuntimeCache::Keyspace).to receive(:delete_keys_by_pattern).and_return(true)
    # Stub MarketData services
    allow(::MarketData::PrecloseCalculator).to receive(:calculate).and_return(0)
    allow(::MarketData::KlineBuilder).to receive(:build).and_return([Time.now.to_i, '0', '0', '0', '0', '0', '0'])
    # Stub realtime topic parser
    allow(::Realtime::TopicParser).to receive(:parse_topic).and_return({ interval: 1440, market_id: nil })
  end

  after do
    Sidekiq::Testing.disable!
  end

  describe '#perform' do
    let(:params) do
      {
        'list_of_pairs' => [['MARKET@1440', Time.current.to_i]],
        'is_init' => false
      }
    end

    let(:mock_market) do
      double('Market',
             market_id: '2800',
             base_currency: 'RON'
      )
    end

    before do
      allow(Trading::Market).to receive(:select).and_return(
        [mock_market]
      )
      allow(ActiveRecord::Base.connection_pool).to receive(:release_connection)
    end

    context 'with valid params' do
      it 'processes market data without error' do
        expect { worker.perform(params) }.not_to raise_error
      end

      it 'updates market data in Redis' do
        expect(::RuntimeCache::MarketDataStore).to receive(:update_market_summary)
          .at_least(:once)
        worker.perform(params)
      end
    end

    context 'with initialization mode' do
      let(:init_params) do
        {
          'list_of_pairs' => [['MARKET@1440', Time.current.to_i]],
          'is_init' => true
        }
      end

      it 'handles initialization without error' do
        expect { worker.perform(init_params) }.not_to raise_error
      end
    end
  end

  describe 'job configuration' do
    it 'uses the default queue' do
      expect(described_class.get_sidekiq_options['queue'].to_s).to eq('default')
    end

    it 'has retry disabled' do
      expect(described_class.get_sidekiq_options['retry']).to eq(false)
    end
  end
end
