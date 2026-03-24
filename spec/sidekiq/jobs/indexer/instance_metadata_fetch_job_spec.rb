# frozen_string_literal: true

require 'rails_helper'
require 'sidekiq/testing'

RSpec.describe Jobs::Indexer::InstanceMetadataFetchJob, type: :job do
  subject(:perform_job) { described_class.new.perform(instance.id) }

  let!(:item) { create(:indexer_item, id: '100') }
  let!(:instance) do
    create(
      :indexer_instance,
      id: '1000065001',
      item_record: item,
      item: item.id,
      metadata_status: 'queued',
      metadata_retry_count: 0
    )
  end
  let(:provider) { instance_double(::Metadata::InstanceMetadata::Providers::ApiProvider) }
  let(:metadata_payload) do
    {
      'name' => 'Puzzle Sword',
      'description' => 'A test metadata payload',
      'image' => 'https://example.com/sword.png',
      'attributes' => []
    }
  end

  before do
    Sidekiq::Testing.fake!
    allow(::Metadata::InstanceMetadata::ProviderRegistry).to receive(:current).and_return(provider)
  end

  after do
    Sidekiq::Testing.disable!
  end

  describe '#perform' do
    context 'when metadata persistence succeeds' do
      before do
        allow(provider).to receive(:fetch).with(instance.id).and_return(success: true, metadata: metadata_payload)
      end

      it 'marks the instance as completed' do
        perform_job

        instance.reload
        expect(instance.metadata_status).to eq('completed')
        expect(instance.metadata_retry_count).to eq(0)
        expect(instance.metadata_error).to be_nil
      end
    end

    context 'when persistence raises after provider fetch succeeds' do
      before do
        allow(provider).to receive(:fetch).with(instance.id).and_return(success: true, metadata: metadata_payload)
        allow_any_instance_of(::Indexer::MetadataFetcher).to receive(:parse_and_save)
          .and_raise(StandardError, 'DB write failed')
      end

      it 'marks the instance as retryable failed state before re-raising' do
        expect { perform_job }.to raise_error(StandardError, 'DB write failed')

        instance.reload
        expect(instance.metadata_status).to eq('pending')
        expect(instance.metadata_retry_count).to eq(1)
        expect(instance.metadata_error).to eq('Persistence failed: DB write failed')
      end
    end
  end

  describe 'job configuration' do
    it 'uses the metadata_fetch queue' do
      expect(described_class.get_sidekiq_options['queue'].to_s).to eq('metadata_fetch')
    end
  end
end
