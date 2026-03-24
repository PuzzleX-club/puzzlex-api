# frozen_string_literal: true

require 'rails_helper'
require 'sidekiq/testing'

RSpec.describe Jobs::Merkle::MerkleTreeGuardianJob, type: :job do
  let(:worker) { described_class.new }

  before do
    Sidekiq::Testing.fake!
    allow(ActionCable.server).to receive(:broadcast)
    # Mock ElectionService
    allow(Sidekiq::Election::Service).to receive(:leader?).and_return(true)
    # Stub cleanup check to avoid DB queries
    allow_any_instance_of(described_class).to receive(:check_cleanup_needed).and_return(false)
  end

  after do
    Sidekiq::Testing.disable!
  end

  describe '#perform' do
    let(:nft_collections) { [28, 29, 30] }

    before do
      allow(Merkle::TreeGenerator).to receive(:get_nft_collection_item_ids)
        .and_return(nft_collections)
    end

    context 'when leader' do
      it 'checks merkle tree status for all collections' do
        allow(Merkle::TreeRoot).to receive(:where).and_return(
          double('relation', order: double('order', first: nil))
        )

        # When no root found, it triggers regeneration for the first collection, then breaks
        expect(Jobs::Merkle::GenerateMerkleTreeJob).to receive(:perform_async)
        expect { worker.perform }.not_to raise_error
      end

      it 'triggers regeneration for outdated trees' do
        # Mock an outdated tree (older than 18 hours)
        old_root = double('MerkleTreeRoot',
          created_at: 20.hours.ago,
          token_count: 100
        )
        allow(Merkle::TreeRoot).to receive(:where).and_return(
          double('relation', order: double('order', first: old_root))
        )
        # Skip token count change check
        allow_any_instance_of(described_class).to receive(:should_check_token_count_change?).and_return(false)

        expect(Jobs::Merkle::GenerateMerkleTreeJob).to receive(:perform_async)
        worker.perform
      end

      it 'skips trees that are up to date' do
        recent_root = double('MerkleTreeRoot',
          created_at: 2.hours.ago,
          token_count: 100
        )
        allow(Merkle::TreeRoot).to receive(:where).and_return(
          double('relation', order: double('order', first: recent_root))
        )
        # Skip token count change check
        allow_any_instance_of(described_class).to receive(:should_check_token_count_change?).and_return(false)

        expect(Jobs::Merkle::GenerateMerkleTreeJob).not_to receive(:perform_async)
        worker.perform
      end
    end

    context 'when not leader' do
      before do
        allow(Sidekiq::Election::Service).to receive(:leader?).and_return(false)
      end

      it 'skips execution' do
        expect(Merkle::TreeGenerator).not_to receive(:get_nft_collection_item_ids)
        worker.perform
      end
    end

    context 'with actual stale tree detection' do
      let(:item_id) { '1129' }

      before do
        allow(Merkle::TreeGenerator).to receive(:get_nft_collection_item_ids)
          .and_return([item_id])
        create(:merkle_tree_root, item_id: item_id, created_at: 19.hours.ago, tree_exists: true)
      end

      it 'detects stale root and enqueues regeneration' do
        # Guardian calls perform_async with no args (dispatch mode)
        expect(Jobs::Merkle::GenerateMerkleTreeJob).to receive(:perform_async).with(no_args)
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

  describe 'job configuration' do
    it 'uses the correct queue' do
      expect(described_class.get_sidekiq_options['queue'].to_s).to eq('scheduler')
    end

    it 'has retry set to 3' do
      expect(described_class.get_sidekiq_options['retry']).to eq(3)
    end
  end
end
