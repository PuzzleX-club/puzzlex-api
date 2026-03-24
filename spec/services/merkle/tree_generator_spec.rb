# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Merkle::TreeGenerator, type: :service do
  before do
    # 使用 ServiceTestHelpers 提供的 stub 方法
    stub_redis
    stub_action_cable
    stub_sidekiq_workers
  end

  # ============================================
  # 哈希计算测试
  # ============================================
  describe '.keccak256_hex' do
    it 'returns hex string with 0x prefix' do
      result = described_class.keccak256_hex('test')

      expect(result).to start_with('0x')
      expect(result.length).to eq(66) # 0x + 64 hex chars
    end

    it 'produces consistent output for same input' do
      result1 = described_class.keccak256_hex('hello')
      result2 = described_class.keccak256_hex('hello')

      expect(result1).to eq(result2)
    end

    it 'produces different output for different input' do
      result1 = described_class.keccak256_hex('hello')
      result2 = described_class.keccak256_hex('world')

      expect(result1).not_to eq(result2)
    end
  end

  describe '.hash_leaf' do
    it 'converts element to hash' do
      result = described_class.hash_leaf(12345)

      expect(result).to start_with('0x')
      expect(result.length).to eq(66)
    end

    it 'produces consistent hashes' do
      result1 = described_class.hash_leaf(1048833)
      result2 = described_class.hash_leaf(1048833)

      expect(result1).to eq(result2)
    end

    it 'handles string token_ids' do
      result = described_class.hash_leaf('1048833')

      expect(result).to start_with('0x')
    end
  end

  describe '.hash_pair' do
    it 'combines two hashes' do
      hash_a = '0x' + 'a' * 64
      hash_b = '0x' + 'b' * 64

      result = described_class.hash_pair(hash_a, hash_b)

      expect(result).to start_with('0x')
      expect(result.length).to eq(66)
    end

    it 'produces same result regardless of order (sorted)' do
      hash_a = '0x' + 'a' * 64
      hash_b = '0x' + 'b' * 64

      result1 = described_class.hash_pair(hash_a, hash_b)
      result2 = described_class.hash_pair(hash_b, hash_a)

      expect(result1).to eq(result2)
    end

    it 'handles hashes without 0x prefix' do
      hash_a = 'a' * 64
      hash_b = 'b' * 64

      result = described_class.hash_pair(hash_a, hash_b)

      expect(result).to start_with('0x')
    end
  end

  # ============================================
  # 树构建测试
  # ============================================
  describe '.build_tree' do
    context 'with single element' do
      it 'creates tree with single leaf as root' do
        elements = [1048833]
        result = described_class.build_tree(elements)

        expect(result[:layers].length).to eq(1)
        expect(result[:root]).to be_present
        expect(result[:layers].first.first[:token_id]).to eq(1048833)
      end
    end

    context 'with two elements' do
      it 'creates tree with two layers' do
        elements = [1048833, 1048834]
        result = described_class.build_tree(elements)

        expect(result[:layers].length).to eq(2)
        expect(result[:root]).to be_present
      end
    end

    context 'with power of 2 elements' do
      it 'creates balanced tree' do
        elements = [1, 2, 3, 4]
        result = described_class.build_tree(elements)

        expect(result[:layers].length).to eq(3) # 4 leaves -> 2 -> 1
        expect(result[:layers][0].length).to eq(4)
        expect(result[:layers][1].length).to eq(2)
        expect(result[:layers][2].length).to eq(1)
      end
    end

    context 'with odd number of elements' do
      it 'handles odd count by duplicating last element' do
        elements = [1, 2, 3]
        result = described_class.build_tree(elements)

        expect(result[:root]).to be_present
        expect(result[:layers][0].length).to eq(3)
      end
    end

    context 'with large number of elements' do
      it 'builds tree correctly' do
        elements = (1..100).to_a
        result = described_class.build_tree(elements)

        expect(result[:root]).to be_present
        expect(result[:layers].first.length).to eq(100)
      end
    end
  end

  # ============================================
  # 根哈希验证
  # ============================================
  describe 'root hash properties' do
    it 'root is deterministic for same elements' do
      elements = [1048833, 1048834, 1048835]
      result1 = described_class.build_tree(elements)
      result2 = described_class.build_tree(elements)

      expect(result1[:root]).to eq(result2[:root])
    end

    it 'root changes when elements change' do
      elements1 = [1048833, 1048834]
      elements2 = [1048833, 1048835]
      result1 = described_class.build_tree(elements1)
      result2 = described_class.build_tree(elements2)

      expect(result1[:root]).not_to eq(result2[:root])
    end

    it 'root is valid hex string' do
      elements = [1, 2, 3, 4]
      result = described_class.build_tree(elements)

      expect(result[:root]).to match(/^0x[a-f0-9]{64}$/)
    end
  end

  # ============================================
  # validate_tokens テスト
  # ============================================
  describe '.validate_tokens' do
    it 'passes for valid token array' do
      expect { described_class.validate_tokens(%w[268724496 268724497 268724498]) }.not_to raise_error
    end

    it 'raises for non-numeric token' do
      expect { described_class.validate_tokens(%w[268724496 abc]) }.to raise_error(/无效的token格式/)
    end

    it 'raises for zero token' do
      expect { described_class.validate_tokens(%w[268724496 0]) }.to raise_error(/token必须为正数/)
    end

    it 'raises for negative token' do
      expect { described_class.validate_tokens(%w[268724496 -1]) }.to raise_error(/无效的token格式/)
    end

    it 'raises for duplicate tokens' do
      expect { described_class.validate_tokens(%w[268724496 268724496]) }.to raise_error(/发现重复的token/)
    end

    it 'passes for string-format tokens' do
      expect { described_class.validate_tokens(%w[1048833 1048834]) }.not_to raise_error
    end
  end

  # ============================================
  # valid_token_format? テスト
  # ============================================
  describe '.valid_token_format?' do
    it 'returns true for valid structured tokenId' do
      expect(described_class.send(:valid_token_format?, '268724496')).to be true
    end

    it 'returns false for blank' do
      expect(described_class.send(:valid_token_format?, '')).to be false
    end

    it 'returns false for nil' do
      expect(described_class.send(:valid_token_format?, nil)).to be false
    end

    it 'returns false for non-numeric string' do
      expect(described_class.send(:valid_token_format?, 'abc')).to be false
    end

    it 'returns false for zero' do
      expect(described_class.send(:valid_token_format?, '0')).to be false
    end

    it 'returns false for too-short token (< 5 chars)' do
      expect(described_class.send(:valid_token_format?, '1234')).to be false
    end

    it 'returns false for too-long token (> 100 chars)' do
      expect(described_class.send(:valid_token_format?, '1' * 101)).to be false
    end
  end

  # ============================================
  # get_optimal_batch_size テスト
  # ============================================
  describe '.get_optimal_batch_size' do
    it 'returns 500 for small datasets (0-1000)' do
      expect(described_class.send(:get_optimal_batch_size, 500)).to eq(500)
    end

    it 'returns 1000 for medium datasets (1001-10000)' do
      expect(described_class.send(:get_optimal_batch_size, 5000)).to eq(1000)
    end

    it 'returns 2000 for large datasets (10001-100000)' do
      expect(described_class.send(:get_optimal_batch_size, 50000)).to eq(2000)
    end

    it 'returns 3000 for very large datasets (100001+)' do
      expect(described_class.send(:get_optimal_batch_size, 200000)).to eq(3000)
    end
  end

  # ============================================
  # persist_tree テスト
  # ============================================
  describe '.persist_tree' do
    let(:elements) { [268724496, 268724497, 268724498] }
    let(:tree_data) { described_class.build_tree(elements) }
    let(:snapshot_id) { "test-#{Time.current.to_i}" }

    it 'creates MerkleTreeNode records for all layers' do
      expect {
        described_class.persist_tree(snapshot_id, '1129', tree_data[:layers], tree_data[:layers].length, 3)
      }.to change(Merkle::TreeNode, :count).by_at_least(elements.length)

      nodes = Merkle::TreeNode.where(snapshot_id: snapshot_id)
      expect(nodes.where(is_leaf: true).count).to eq(elements.length)
      expect(nodes.where(is_root: true).count).to eq(1)
      expect(nodes.pluck(:level).uniq.sort).to eq((0...tree_data[:layers].length).to_a)
    end

    it 'persists leaf nodes with correct token_ids at level 0' do
      described_class.persist_tree(snapshot_id, '1129', tree_data[:layers], tree_data[:layers].length, 3)
      leaves = Merkle::TreeNode.where(snapshot_id: snapshot_id, is_leaf: true)
      expect(leaves.pluck(:level).uniq).to eq([0])
      expect(leaves.pluck(:token_id).compact.map(&:to_s).sort).to eq(elements.map(&:to_s).sort)
    end

    it 'persists root node with item_id, tree_height, and total_tokens' do
      described_class.persist_tree(snapshot_id, '1129', tree_data[:layers], tree_data[:layers].length, 3)
      root = Merkle::TreeNode.find_by(snapshot_id: snapshot_id, is_root: true)
      expect(root).to be_present
      expect(root.item_id.to_s).to eq('1129')
      expect(root.tree_height).to eq(tree_data[:layers].length)
      expect(root.total_tokens).to eq(3)
      expect(root.node_hash).to eq(tree_data[:root])
    end
  end

  # ============================================
  # generate_and_persist テスト
  # ============================================
  describe '.generate_and_persist' do
    let(:item_id) { '1129' }
    let(:mock_tokens) { %w[268724496 268724497 268724498] }

    before do
      allow(described_class).to receive(:get_tokens_for_item).with(item_id).and_return(mock_tokens)
    end

    it 'creates MerkleTreeRoot and MerkleTreeNode records' do
      result = described_class.generate_and_persist(item_id)
      expect(result[:snapshot_id]).to be_present
      expect(result[:merkle_root]).to start_with('0x')
      expect(result[:token_count]).to eq(3)

      root_record = Merkle::TreeRoot.find_by(snapshot_id: result[:snapshot_id])
      expect(root_record).to be_present
      expect(root_record.tree_exists).to be true
      expect(root_record.token_count).to eq(3)
    end

    it 'raises when no tokens found' do
      allow(described_class).to receive(:get_tokens_for_item).with('9999').and_return([])
      expect { described_class.generate_and_persist('9999') }.to raise_error(/没有找到对应的token/)
    end

    it 'raises when token count exceeds max limit' do
      huge_tokens = (100000..200001).map(&:to_s)
      allow(described_class).to receive(:get_tokens_for_item).with(item_id).and_return(huge_tokens)
      expect { described_class.generate_and_persist(item_id) }.to raise_error(/超过系统限制/)
    end

    it 'returns correct hash structure' do
      result = described_class.generate_and_persist(item_id)
      expect(result).to include(:snapshot_id, :merkle_root, :token_count, :tree_height, :generation_duration_ms)
    end
  end
end
