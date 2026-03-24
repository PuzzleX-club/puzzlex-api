# frozen_string_literal: true

require 'rails_helper'
require 'sidekiq/testing'

RSpec.describe Jobs::Indexer::EventProcessingWorker, type: :job do
  let(:worker) { described_class.new }

  before do
    Sidekiq::Testing.fake!
  end

  after do
    Sidekiq::Testing.disable!
  end

  describe '#perform' do
    let(:event_data) do
      {
        'name' => 'OrderFulfilled',
        'data' => { 'transaction_hash' => '0x' + SecureRandom.hex(32) },
        'metadata' => { 'block_number' => 12345 }
      }
    end

    let(:subscribers_data) do
      [
        { 'listener_class' => 'String', 'method_name' => 'length' }
      ]
    end

    context 'with valid event data' do
      before do
        # Mock subscriber processing to avoid needing real listener classes
        allow_any_instance_of(described_class).to receive(:process_subscriber)
          .and_return(true)
      end

      it 'enqueues the job' do
        expect {
          described_class.perform_async(event_data, subscribers_data)
        }.to change(described_class.jobs, :size).by(1)
      end
    end

    context 'with subscriber processing error' do
      before do
        allow_any_instance_of(described_class).to receive(:process_subscriber)
          .and_raise(StandardError, 'Processing error')
      end

      it 'raises the error for Sidekiq retry' do
        expect { worker.perform(event_data, subscribers_data) }.to raise_error(StandardError, 'Processing error')
      end
    end
  end

  describe 'job configuration' do
    it 'uses the correct queue' do
      expect(described_class.get_sidekiq_options['queue'].to_s).to eq('events')
    end
  end
end
