# frozen_string_literal: true

require 'rails_helper'
require 'sidekiq/testing'

# Ensure Sharding dispatcher is loaded
require_relative '../../../../app/services/sidekiq/sharding/dispatcher'

RSpec.describe Jobs::Merkle::GenerateMerkleTreeJob, type: :job do
  let(:worker) { described_class.new }

  before do
    Sidekiq::Testing.fake!
    allow(ActionCable.server).to receive(:broadcast)
    # Mock ElectionService
    allow(Sidekiq::Election::Service).to receive(:leader?).and_return(true)
    # Mock ShardingDispatcher
    allow(Sidekiq::Sharding::Dispatcher).to receive(:new).and_return(
      double('Dispatcher', active_instance_count: 2, dispatch_batch: true)
    )
  end

  after do
    Sidekiq::Testing.disable!
  end

  describe '#perform' do
    context 'in dispatch mode (no arguments)' do
      before do
        allow(Merkle::TreeGenerator).to receive(:get_nft_collection_item_ids)
          .and_return([28, 29, 30])
      end

      it 'dispatches merkle tree generation for all NFT collections' do
        dispatcher = double('Dispatcher', active_instance_count: 2, dispatch_batch: true)
        allow(Sidekiq::Sharding::Dispatcher).to receive(:new).and_return(dispatcher)

        expect(dispatcher).to receive(:dispatch_batch).with(described_class, [28, 29, 30])
        worker.perform
      end

      it 'skips when not leader' do
        allow(Sidekiq::Election::Service).to receive(:leader?).and_return(false)
        expect(Merkle::TreeGenerator).not_to receive(:get_nft_collection_item_ids)
        worker.perform
      end

      it 'handles empty NFT collections' do
        allow(Merkle::TreeGenerator).to receive(:get_nft_collection_item_ids)
          .and_return([])
        expect { worker.perform }.not_to raise_error
      end
    end

    context 'in slice mode (with target_item_ids)' do
      let(:item_ids) { [28, 29] }

      before do
        allow(Merkle::TreeGenerator).to receive(:generate_and_persist)
          .and_return({ snapshot_id: 'abc123', merkle_root: '0xabc123456789' })
      end

      it 'generates merkle trees for specified items' do
        expect(Merkle::TreeGenerator).to receive(:generate_and_persist)
          .exactly(2).times
        worker.perform(item_ids)
      end

      it 'handles generation errors gracefully' do
        allow(Merkle::TreeGenerator).to receive(:generate_and_persist)
          .and_raise(StandardError, 'Generation failed')
        expect { worker.perform(item_ids) }.not_to raise_error
      end
    end

    context 'slice mode with actual generator (non-mock path)' do
      let(:item_id) { 1129 }
      let(:mock_tokens) { %w[268724496 268724497 268724498] }

      before do
        # Job converts to integer via .map(&:to_i), so stub with integer
        allow(Merkle::TreeGenerator).to receive(:get_tokens_for_item)
          .with(item_id).and_return(mock_tokens)
      end

      it 'actually creates merkle tree records in DB' do
        expect {
          worker.perform([item_id])
        }.to change(Merkle::TreeRoot, :count).by(1)
          .and change(Merkle::TreeNode, :count).by_at_least(3)

        root = Merkle::TreeRoot.order(created_at: :desc).first
        expect(root.item_id.to_s).to eq(item_id.to_s)
        expect(root.tree_exists).to be true
        expect(root.token_count).to eq(3)
      end
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
