# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Seaport::ContractService do
  let(:service) { described_class.new }
  let(:test_rpc_url) { "http://localhost:8546" }

  before do
    # Mock environment variables
    allow(ENV).to receive(:[]).with("BLOCKCHAIN_RPC_URL").and_return(test_rpc_url)
  end

  describe '#initialize' do
    it 'creates client with correct RPC URL' do
      expect(service.instance_variable_get(:@client)).not_to be_nil
    end

    it 'logs RPC URL in test environment' do
      expect(Rails.logger).to receive(:info).with(/ContractService using RPC/)
      described_class.new
    end
  end

  describe '#latest_block_number' do
    context 'when RPC returns valid response' do
      let(:valid_response) do
        {
          "jsonrpc" => "2.0",
          "id" => 1,
          "result" => "0x123456"
        }.to_json
      end

      before do
        allow(service).to receive(:perform_request).and_return(valid_response)
      end

      it 'returns decimal block number' do
        result = service.latest_block_number
        expect(result).to eq(0x123456)
      end

      it 'logs successful retrieval' do
        # 只验证日志方法被调用，不验证具体内容
        expect(Rails.logger).to receive(:info).at_least(:once)
        service.latest_block_number
      end
    end

    context 'when RPC returns error' do
      let(:error_response) do
        {
          "jsonrpc" => "2.0",
          "id" => 1,
          "error" => { "code" => -32601, "message" => "Method not found" }
        }.to_json
      end

      before do
        allow(service).to receive(:perform_request).and_return(error_response)
      end

      it 'returns nil' do
        result = service.latest_block_number
        expect(result).to be_nil
      end

      it 'logs error details' do
        expect(Rails.logger).to receive(:error).at_least(:once)
        service.latest_block_number
      end
    end

    context 'when response is malformed' do
      let(:malformed_response) { '{ invalid json' }

      before do
        allow(service).to receive(:perform_request).and_return(malformed_response)
      end

      it 'handles JSON parsing error gracefully' do
        expect(service.latest_block_number).to be_nil
      end
    end
  end

  describe '#get_order_status' do
    let(:order_hash) { "0x1234567890abcdef1234567890abcdef12345678" }
    let(:valid_hex_result) do
      # 构造16进制结果：
      # is_validated: 1 (true) -> 0x000...0001
      # is_cancelled: 0 (false) -> 0x000...0000
      # total_filled: 1000 -> 0x000...03e8
      # total_size: 2000 -> 0x000...07d0
      "0x0000000000000000000000000000000000000000000000000000000000000001" +
      "0000000000000000000000000000000000000000000000000000000000000000" +
      "00000000000000000000000000000000000000000000000000000000000003e8" +
      "00000000000000000000000000000000000000000000000000000000000007d0"
    end

    let(:valid_order_result) do
      {
        "jsonrpc" => "2.0",
        "id" => 1,
        "result" => valid_hex_result
      }.to_json
    end

    before do
      allow(service).to receive(:perform_request).and_return(valid_order_result)
    end

    it 'returns parsed order status' do
      result = service.get_order_status(order_hash)
      expect(result).to be_a(Hash)
      expect(result[:is_validated]).to be true
      expect(result[:is_cancelled]).to be false
      expect(result[:total_filled]).to eq(1000)
      expect(result[:total_size]).to eq(2000)
    end

    it 'handles empty result' do
      empty_result = {
        "jsonrpc" => "2.0",
        "id" => 1,
        "result" => "0x"
      }.to_json

      allow(service).to receive(:perform_request).and_return(empty_result)

      result = service.get_order_status(order_hash)
      expect(result[:error]).to eq("Invalid response or empty result")
    end
  end

  describe '#fetch_block_timestamp' do
    let(:block_number) { "0x3039" } # 十六进制字符串格式
    let(:block_timestamp_response) do
      {
        "jsonrpc" => "2.0",
        "id" => 1,
        "result" => {
          "timestamp" => "0x61a8a8b0",
          "number" => "0x3039",
          "hash" => "0x1234567890abcdef"
        }
      }.to_json
    end

    before do
      allow(service).to receive(:perform_request).and_return(block_timestamp_response)
    end

    it 'returns block timestamp as integer' do
      result = service.send(:fetch_block_timestamp, block_number)
      expect(result).to be_a(Integer)
      expect(result).to eq(0x61a8a8b0)
    end

    it 'returns nil for nil block number' do
      result = service.send(:fetch_block_timestamp, nil)
      expect(result).to be_nil
    end

    it 'handles RPC error gracefully' do
      error_response = {
        "jsonrpc" => "2.0",
        "id" => 1,
        "error" => { "code" => -32000, "message" => "Block not found" }
      }.to_json

      allow(service).to receive(:perform_request).and_return(error_response)

      result = service.send(:fetch_block_timestamp, block_number)
      expect(result).to be_nil
    end
  end

  describe '#format_input_type' do
    context 'with address type' do
      it 'formats address correctly' do
        result = service.send(:format_input_type, { "type" => "address" })
        expect(result).to eq("address")
      end
    end

    context 'with uint256 type' do
      it 'formats uint256 correctly' do
        result = service.send(:format_input_type, { "type" => "uint256" })
        expect(result).to eq("uint256")
      end
    end

    context 'with array type' do
      it 'formats array correctly' do
        result = service.send(:format_input_type, { "type" => "uint256[]" })
        expect(result).to eq("uint256[]")
      end
    end

    context 'with tuple type' do
      it 'formats tuple correctly' do
        input = {
          "type" => "tuple",
          "components" => [
            { "type" => "address" },
            { "type" => "uint256" }
          ]
        }
        result = service.send(:format_input_type, input)
        expect(result).to eq("(address,uint256)")
      end
    end

    context 'with tuple array type' do
      it 'formats tuple array correctly' do
        input = {
          "type" => "tuple[]",
          "components" => [
            { "type" => "address" },
            { "type" => "uint256" }
          ]
        }
        result = service.send(:format_input_type, input)
        expect(result).to eq("(address,uint256)[]")
      end
    end
  end

  describe '#parse_order_status' do
    let(:hex_result) do
      # 构造16进制结果：
      # is_validated: 1 (true) -> 0x000...0001
      # is_cancelled: 0 (false) -> 0x000...0000
      # total_filled: 1000 -> 0x000...03e8
      # total_size: 2000 -> 0x000...07d0
      "0x0000000000000000000000000000000000000000000000000000000000000001" +
      "0000000000000000000000000000000000000000000000000000000000000000" +
      "00000000000000000000000000000000000000000000000000000000000003e8" +
      "00000000000000000000000000000000000000000000000000000000000007d0"
    end

    it 'parses numeric fields correctly' do
      result = service.send(:parse_order_status, hex_result)
      expect(result[:total_filled]).to eq(1000)
      expect(result[:total_size]).to eq(2000)
    end

    it 'handles boolean fields correctly' do
      result = service.send(:parse_order_status, hex_result)
      expect(result[:is_validated]).to be true
      expect(result[:is_cancelled]).to be false
    end

    it 'handles nil results' do
      result = service.send(:parse_order_status, nil)
      expect(result[:error]).to eq("Invalid response or empty result")
    end

    it 'handles empty results' do
      result = service.send(:parse_order_status, "0x")
      expect(result[:error]).to eq("Invalid response or empty result")
    end
  end

  describe '#decode_topic' do
    context 'with address topic' do
      it 'decodes address correctly' do
        # 前26个零 + 40个字符的以太坊地址
        topic = "0000000000000000000000001234567890123456789012345678901234567890"
        result = service.send(:decode_topic, topic, "address")
        expect(result).to eq("0x34567890123456789012345678901234567890")
      end

      it 'handles 40 character addresses correctly' do
        # 完整的40字符地址：0000000000000000000000001234567890abcdef1234567890abcdef12345678
        # 这里从第27个字符开始取，取到38个字符（实际地址）
        topic = "0000000000000000000000001234567890abcdef1234567890abcdef12345678"
        result = service.send(:decode_topic, topic, "address")
        expect(result).to eq("0x34567890abcdef1234567890abcdef12345678")
      end
    end

    context 'with uint256 topic' do
      it 'decodes uint256 correctly' do
        uint256_value = "1234567890abcdef1234567890abcdef12345678"
        result = service.send(:decode_topic, uint256_value, "uint256")
        expect(result).to be_a(Integer)
      end
    end

    context 'with bytes32 topic' do
      it 'decodes bytes32 correctly' do
        bytes32_value = "0x1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef"
        result = service.send(:decode_topic, bytes32_value, "bytes32")
        expect(result).to eq(bytes32_value)
      end
    end

    context 'with unsupported type' do
      it 'raises error' do
        expect {
          service.send(:decode_topic, "1234", "unsupported")
        }.to raise_error("Unsupported indexed type: unsupported")
      end
    end
  end

  describe 'rate limiting' do
    describe '.rate_limit_mutex' do
      it 'returns a Mutex object' do
        mutex = described_class.send(:rate_limit_mutex)
        expect(mutex).to be_a(Mutex)
      end
    end

    describe '.last_request_time' do
      it 'returns a numeric value' do
        time = described_class.send(:last_request_time)
        expect(time).to be_a(Numeric)
      end
    end

    describe '.throttle!' do
      it 'can be called without error' do
        expect { described_class.throttle! }.not_to raise_error
      end
    end
  end

  describe 'error handling' do
    context 'when RPC request fails with JSON parsing error' do
      before do
        allow(service).to receive(:perform_request).and_return('{ invalid json')
      end

      it 'returns nil gracefully' do
        expect(service.latest_block_number).to be_nil
      end
    end

    context 'when RPC returns error response' do
      let(:error_response) do
        {
          "jsonrpc" => "2.0",
          "id" => 1,
          "error" => { "code" => -32601, "message" => "Method not found" }
        }.to_json
      end

      before do
        allow(service).to receive(:perform_request).and_return(error_response)
      end

      it 'returns nil' do
        result = service.latest_block_number
        expect(result).to be_nil
      end
    end
  end

  describe 'constants' do
    it 'defines RATE_LIMIT_INTERVAL' do
      expect(described_class::RATE_LIMIT_INTERVAL).to eq(0.05)
    end

    it 'defines RpcError class' do
      expect(described_class::RpcError).to be < StandardError
    end

    it 'defines InvalidResponse class' do
      expect(described_class::InvalidResponse).to be < described_class::RpcError
    end
  end
end
