# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Matching::State::QueueManager do
  include ServiceTestHelpers

  let(:market_id) { 101 }

  let(:valid_match_data) do
    {
      market_id: market_id,
      orders: [
        { order_hash: '0xorder1', parameters: {} },
        { order_hash: '0xorder2', parameters: {} }
      ],
      fulfillments: [
        { orderIndex: 0, itemIndex: 0 }
      ]
    }
  end

  # Create a fresh instance for each test to avoid singleton issues
  let(:instance) do
    # Reset the singleton
    described_class.instance_variable_set(:@singleton__instance__, nil)
    described_class.instance
  end

  let(:redis) do
    redis_double = instance_double(Redis)
    allow(redis_double).to receive(:lpush).and_return(1)
    allow(redis_double).to receive(:rpop).and_return(nil)
    allow(redis_double).to receive(:brpop).and_return(nil)
    allow(redis_double).to receive(:llen).and_return(0)
    allow(redis_double).to receive(:lrange).and_return([])
    allow(redis_double).to receive(:del).and_return(1)
    allow(redis_double).to receive(:expire).and_return(true)
    allow(redis_double).to receive(:keys).and_return([])
    redis_double
  end

  before do
    allow(Sidekiq).to receive(:redis).and_yield(redis)
  end

  describe '#enqueue_match' do
    it 'adds match data to redis queue' do
      expect(redis).to receive(:lpush).with("match_queue:#{market_id}", anything).and_return(1)

      result = instance.enqueue_match(market_id, valid_match_data)

      expect(result).to eq(1)
    end

    it 'sets queue expiration time' do
      expect(redis).to receive(:expire).with("match_queue:#{market_id}", 3600)

      instance.enqueue_match(market_id, valid_match_data)
    end

    it 'adds queued_at timestamp to data' do
      captured_data = nil
      allow(redis).to receive(:lpush) do |_key, json_data|
        captured_data = JSON.parse(json_data, symbolize_names: true)
        1
      end

      instance.enqueue_match(market_id, valid_match_data)

      expect(captured_data[:queued_at]).to be_present
    end

    it 'adds metadata to data' do
      captured_data = nil
      allow(redis).to receive(:lpush) do |_key, json_data|
        captured_data = JSON.parse(json_data, symbolize_names: true)
        1
      end

      instance.enqueue_match(market_id, valid_match_data)

      expect(captured_data[:metadata][:source]).to eq('rails_matcher')
      expect(captured_data[:metadata][:version]).to eq('2.0')
    end

    it 'raises error for nil match data' do
      expect {
        instance.enqueue_match(market_id, nil)
      }.to raise_error(StandardError)
    end

    it 'raises error for missing orders' do
      expect {
        instance.enqueue_match(market_id, { fulfillments: [] })
      }.to raise_error(StandardError)
    end

    it 'raises error for missing fulfillments' do
      expect {
        instance.enqueue_match(market_id, { orders: [{}] })
      }.to raise_error(StandardError)
    end

    it 'includes criteriaResolvers when present' do
      match_data_with_criteria = valid_match_data.merge(
        criteriaResolvers: [{ orderIndex: 0, side: 'offer' }]
      )

      captured_data = nil
      allow(redis).to receive(:lpush) do |_key, json_data|
        captured_data = JSON.parse(json_data, symbolize_names: true)
        1
      end

      instance.enqueue_match(market_id, match_data_with_criteria)

      expect(captured_data[:criteriaResolvers]).to be_present
    end

    it 'includes partialFillOptions when present' do
      match_data_with_partial = valid_match_data.merge(
        partialFillOptions: [{ orderIndex: 0, amount: 5 }]
      )

      captured_data = nil
      allow(redis).to receive(:lpush) do |_key, json_data|
        captured_data = JSON.parse(json_data, symbolize_names: true)
        1
      end

      instance.enqueue_match(market_id, match_data_with_partial)

      expect(captured_data[:partialFillOptions]).to be_present
    end

    it 'requires fills for v2 match data' do
      v2_without_fills = valid_match_data.merge(match_data_version: 'v2')

      expect {
        instance.enqueue_match(market_id, v2_without_fills)
      }.to raise_error(StandardError, /v2 must have fills/)
    end

    it 'rejects partialFillOptions for v2 strict mode' do
      v2_with_partial = valid_match_data.merge(
        match_data_version: 'v2',
        fills: [{ ask_hash: '0xorder2', filled_qty: 1 }],
        partialFillOptions: [{ orderIndex: 0, amount: 5 }]
      )

      expect {
        instance.enqueue_match(market_id, v2_with_partial)
      }.to raise_error(StandardError, /does not allow partialFillOptions/)
    end
  end

  describe '#dequeue_match' do
    let(:queued_data) do
      {
        queued_at: Time.current.to_f,
        market_id: market_id,
        orders: valid_match_data[:orders],
        fulfillments: valid_match_data[:fulfillments],
        orders_hash: ['0xorder1', '0xorder2'],
        metadata: { source: 'rails_matcher', version: '2.0' }
      }.to_json
    end

    it 'returns nil when queue is empty' do
      result = instance.dequeue_match(market_id)

      expect(result).to be_nil
    end

    it 'returns parsed match data when available' do
      allow(redis).to receive(:rpop).and_return(queued_data)

      result = instance.dequeue_match(market_id)

      expect(result).to be_a(Hash)
      expect(result[:market_id]).to eq(market_id)
      expect(result[:orders]).to be_present
    end

    it 'uses blocking pop with timeout when specified' do
      expect(redis).to receive(:brpop).with("match_queue:#{market_id}", timeout: 5).and_return(nil)

      instance.dequeue_match(market_id, timeout: 5)
    end

    it 'handles JSON parse errors gracefully' do
      allow(redis).to receive(:rpop).and_return('invalid json')

      result = instance.dequeue_match(market_id)

      expect(result).to be_nil
    end

    it 'rejects invalid v2 payload without fills' do
      invalid_v2 = {
        queued_at: Time.current.to_f,
        market_id: market_id,
        match_data_version: 'v2',
        orders: valid_match_data[:orders],
        fulfillments: valid_match_data[:fulfillments]
      }.to_json
      allow(redis).to receive(:rpop).and_return(invalid_v2)

      result = instance.dequeue_match(market_id)

      expect(result).to be_nil
    end
  end

  describe '#batch_dequeue_matches' do
    let(:queued_data) do
      {
        queued_at: Time.current.to_f,
        market_id: market_id,
        orders: valid_match_data[:orders],
        fulfillments: valid_match_data[:fulfillments]
      }.to_json
    end

    it 'returns empty array when queue is empty' do
      result = instance.batch_dequeue_matches(market_id)

      expect(result).to eq([])
    end

    it 'dequeues up to batch_size items' do
      call_count = 0
      allow(redis).to receive(:rpop) do
        call_count += 1
        call_count <= 3 ? queued_data : nil
      end

      result = instance.batch_dequeue_matches(market_id, batch_size: 5)

      expect(result.length).to eq(3)
    end

    it 'respects batch_size limit' do
      allow(redis).to receive(:rpop).and_return(queued_data)

      result = instance.batch_dequeue_matches(market_id, batch_size: 2)

      expect(result.length).to eq(2)
    end

    it 'skips invalid v2 payload in batch dequeue' do
      invalid_v2 = {
        queued_at: Time.current.to_f,
        market_id: market_id,
        match_data_version: 'v2',
        orders: valid_match_data[:orders],
        fulfillments: valid_match_data[:fulfillments]
      }.to_json
      allow(redis).to receive(:rpop).and_return(invalid_v2, queued_data, nil)

      result = instance.batch_dequeue_matches(market_id, batch_size: 3)

      expect(result.size).to eq(1)
      expect(result.first[:market_id]).to eq(market_id)
    end
  end

  describe '#enqueue_recovery' do
    let(:recovery_data) do
      {
        market_id: market_id,
        orders: valid_match_data[:orders],
        error: 'Transaction failed'
      }
    end

    it 'adds recovery data to failed queue' do
      expect(redis).to receive(:lpush).with("match_failed_queue:#{market_id}", anything)

      instance.enqueue_recovery(market_id, recovery_data)
    end

    it 'adds failed_at timestamp if not present' do
      captured_data = nil
      allow(redis).to receive(:lpush) do |_key, json_data|
        captured_data = JSON.parse(json_data, symbolize_names: true)
        1
      end

      instance.enqueue_recovery(market_id, recovery_data)

      expect(captured_data[:failed_at]).to be_present
    end

    it 'adds retry_count if not present' do
      captured_data = nil
      allow(redis).to receive(:lpush) do |_key, json_data|
        captured_data = JSON.parse(json_data, symbolize_names: true)
        1
      end

      instance.enqueue_recovery(market_id, recovery_data)

      expect(captured_data[:retry_count]).to eq(0)
    end

    it 'preserves existing retry_count' do
      data_with_retry = recovery_data.merge(retry_count: 3)
      captured_data = nil
      allow(redis).to receive(:lpush) do |_key, json_data|
        captured_data = JSON.parse(json_data, symbolize_names: true)
        1
      end

      instance.enqueue_recovery(market_id, data_with_retry)

      expect(captured_data[:retry_count]).to eq(3)
    end
  end

  describe '#dequeue_recovery' do
    let(:recovery_data) do
      {
        market_id: market_id,
        failed_at: Time.current.to_f,
        retry_count: 1
      }.to_json
    end

    it 'returns nil when failed queue is empty' do
      result = instance.dequeue_recovery(market_id)

      expect(result).to be_nil
    end

    it 'returns parsed recovery data when available' do
      allow(redis).to receive(:rpop).and_return(recovery_data)

      result = instance.dequeue_recovery(market_id)

      expect(result).to be_a(Hash)
      expect(result[:retry_count]).to eq(1)
    end
  end

  describe '#queue_depth' do
    it 'returns queue length from redis' do
      allow(redis).to receive(:llen).with("match_queue:#{market_id}").and_return(5)

      result = instance.queue_depth(market_id)

      expect(result).to eq(5)
    end
  end

  describe '#failed_queue_depth' do
    it 'returns failed queue length from redis' do
      allow(redis).to receive(:llen).with("match_failed_queue:#{market_id}").and_return(3)

      result = instance.failed_queue_depth(market_id)

      expect(result).to eq(3)
    end
  end

  describe '#all_queue_status' do
    it 'returns empty hash when no queues exist' do
      result = instance.all_queue_status

      expect(result).to eq({})
    end

    it 'returns status for all queues' do
      allow(redis).to receive(:keys).with('match_queue:*').and_return(['match_queue:101', 'match_queue:102'])
      allow(redis).to receive(:keys).with('match_failed_queue:*').and_return(['match_failed_queue:101'])
      allow(redis).to receive(:llen).with('match_queue:101').and_return(5)
      allow(redis).to receive(:llen).with('match_queue:102').and_return(3)
      allow(redis).to receive(:llen).with('match_failed_queue:101').and_return(1)

      result = instance.all_queue_status

      expect(result['101'][:match_queue_depth]).to eq(5)
      expect(result['101'][:failed_queue_depth]).to eq(1)
      expect(result['102'][:match_queue_depth]).to eq(3)
    end
  end

  describe '#peek_queue' do
    it 'returns empty array when queue is empty' do
      result = instance.peek_queue(market_id)

      expect(result).to eq([])
    end

    it 'returns parsed queue items without removing them' do
      items = [
        { queued_at: Time.current.to_f, market_id: market_id }.to_json,
        { queued_at: Time.current.to_f - 10, market_id: market_id }.to_json
      ]
      allow(redis).to receive(:lrange).and_return(items)

      result = instance.peek_queue(market_id, count: 2)

      expect(result.length).to eq(2)
      expect(result.first[:market_id]).to eq(market_id)
    end

    it 'filters out items with invalid JSON' do
      items = [
        { queued_at: Time.current.to_f }.to_json,
        'invalid json'
      ]
      allow(redis).to receive(:lrange).and_return(items)

      result = instance.peek_queue(market_id)

      expect(result.length).to eq(1)
    end
  end

  describe '#clear_queue' do
    it 'deletes the queue and returns count' do
      allow(redis).to receive(:llen).with("match_queue:#{market_id}").and_return(5)
      expect(redis).to receive(:del).with("match_queue:#{market_id}")

      result = instance.clear_queue(market_id)

      expect(result).to eq(5)
    end
  end

  describe '#clear_failed_queue' do
    it 'deletes the failed queue and returns count' do
      allow(redis).to receive(:llen).with("match_failed_queue:#{market_id}").and_return(3)
      expect(redis).to receive(:del).with("match_failed_queue:#{market_id}")

      result = instance.clear_failed_queue(market_id)

      expect(result).to eq(3)
    end
  end

  describe 'class methods' do
    it '.enqueue_match delegates to instance' do
      expect(instance).to receive(:enqueue_match).with(market_id, valid_match_data)

      described_class.enqueue_match(market_id, valid_match_data)
    end

    it '.dequeue_match delegates to instance' do
      expect(instance).to receive(:dequeue_match).with(market_id, timeout: nil)

      described_class.dequeue_match(market_id)
    end

    it '.queue_depth delegates to instance' do
      expect(instance).to receive(:queue_depth).with(market_id)

      described_class.queue_depth(market_id)
    end
  end
end
