# frozen_string_literal: true

require 'eth'
require 'faraday'

module Indexer
  # NFT合约服务
  # 用于查询ERC1155 Transfer事件
  class NFTContractService
    RATE_LIMIT_INTERVAL = 0.05 # 50ms间隔，约20请求/秒

    class RpcError < StandardError; end

    # ERC1155事件ABI定义
    ERC1155_EVENTS = {
      'TransferSingle' => {
        'name' => 'TransferSingle',
        'inputs' => [
          { 'name' => 'operator', 'type' => 'address', 'indexed' => true },
          { 'name' => 'from', 'type' => 'address', 'indexed' => true },
          { 'name' => 'to', 'type' => 'address', 'indexed' => true },
          { 'name' => 'id', 'type' => 'uint256', 'indexed' => false },
          { 'name' => 'value', 'type' => 'uint256', 'indexed' => false }
        ]
      },
      'TransferBatch' => {
        'name' => 'TransferBatch',
        'inputs' => [
          { 'name' => 'operator', 'type' => 'address', 'indexed' => true },
          { 'name' => 'from', 'type' => 'address', 'indexed' => true },
          { 'name' => 'to', 'type' => 'address', 'indexed' => true },
          { 'name' => 'ids', 'type' => 'uint256[]', 'indexed' => false },
          { 'name' => 'values', 'type' => 'uint256[]', 'indexed' => false }
        ]
      }
    }.freeze

    def initialize
      @rpc_endpoint = config.rpc_endpoint
      @block_timestamps = {} # 区块时间戳缓存
      @connection = build_connection
    end

    # 获取最新区块号
    def latest_block_number
      response = perform_request('eth_blockNumber', [])

      if response['result']
        response['result'].to_i(16)
      else
        Rails.logger.error "[NFTContractService] 获取区块号失败: #{response['error']}"
        nil
      end
    end

    # 获取NFT Transfer事件
    def get_event_logs(event_name:, from_block:, to_block:, contract_address:)
      event = ERC1155_EVENTS[event_name]
      raise RpcError, "Unknown NFT event: #{event_name}" unless event

      # 生成事件topic
      event_signature = "#{event['name']}(#{event['inputs'].map { |i| i['type'] }.join(',')})"
      event_topic = '0x' + Eth::Util.keccak256(event_signature).unpack1('H*')

      # 转换区块号为hex
      from_block_hex = '0x' + from_block.to_i.to_s(16)
      to_block_hex = '0x' + to_block.to_i.to_s(16)

      params = [{
        fromBlock: from_block_hex,
        toBlock: to_block_hex,
        address: contract_address,
        topics: [event_topic]
      }]

      response = perform_request('eth_getLogs', params)

      if response['error']
        raise RpcError, response['error'].inspect
      end

      result = response['result']
      return [] unless result.is_a?(Array)

      decode_logs(event, result)
    end

    # 对外暴露：解码单条日志（供统一 collector 使用）
    def decode_raw_log(log, event_name:)
      event = ERC1155_EVENTS[event_name]
      raise RpcError, "Unknown NFT event: #{event_name}" unless event

      decode_event_log(event, log)
    end

    private

    def config
      Rails.application.config.x.indexer
    end

    def build_connection
      Faraday.new(url: @rpc_endpoint) do |faraday|
        faraday.request :json
        faraday.request :retry, {
          max: 2,                    # 减少重试次数（从 3 → 2）
          interval: 0.3,
          interval_randomness: 0.3,
          backoff_factor: 2,
          exceptions: [
            Faraday::TimeoutError,
            Faraday::ConnectionFailed,
            Faraday::SSLError
          ]
        }
        faraday.response :json
        faraday.adapter Faraday.default_adapter
        faraday.options.timeout = 30       # 减少超时（60 → 30秒）
        faraday.options.open_timeout = 10  # 减少连接超时（15 → 10秒）

        # SSL 配置（解决 SSL handshake 问题）
        faraday.ssl.verify = true
        faraday.ssl.verify_mode = OpenSSL::SSL::VERIFY_PEER
      end
    end

    # 执行RPC请求（带速率限制）
    def perform_request(method, params)
      # 全局速率限制
      @@last_request_time ||= Time.now - RATE_LIMIT_INTERVAL
      elapsed = Time.now - @@last_request_time
      if elapsed < RATE_LIMIT_INTERVAL
        sleep(RATE_LIMIT_INTERVAL - elapsed)
      end
      @@last_request_time = Time.now

      request_body = {
        jsonrpc: '2.0',
        method: method,
        params: params,
        id: rand(1..10000)
      }

      response = @connection.post do |req|
        req.headers['Content-Type'] = 'application/json'
        req.body = request_body.to_json
      end

      response.body
    rescue StandardError => e
      Rails.logger.error "[NFTContractService] RPC请求失败: #{e.message}"
      raise RpcError, e.message
    end

    # 解码事件日志
    def decode_logs(event, logs)
      decoded_logs = []

      logs.each do |log|
        decoded = decode_event_log(event, log)
        decoded_logs << decoded.merge(
          transaction_hash: log['transactionHash'],
          log_index: log['logIndex'].to_i(16),
          block_number: log['blockNumber'].to_i(16),
          block_hash: log['blockHash'],
          timestamp: fetch_block_timestamp(log['blockNumber'])
        )
      rescue StandardError => e
        Rails.logger.error "[NFTContractService] 解析事件失败: #{e.message}"
        Rails.logger.error "  log: #{log.inspect}"
      end

      decoded_logs
    end

    # 解码单个事件日志
    def decode_event_log(event, log)
      inputs = event['inputs']
      indexed_inputs = inputs.select { |i| i['indexed'] }
      non_indexed_inputs = inputs.reject { |i| i['indexed'] }

      decoded = {}

      # 解码indexed参数（topics）
      indexed_inputs.each_with_index do |input, index|
        topic = log['topics'][index + 1] # topics[0]是事件签名
        decoded[input['name'].to_sym] = decode_topic(topic, input['type'])
      end

      # 解码non-indexed参数（data）
      if non_indexed_inputs.any?
        data = log['data'][2..] # 去除0x
        types = non_indexed_inputs.map { |i| i['type'] }

        values = Blockchain::AbiCoder.new.decode_data("(#{types.join(',')})", data)

        non_indexed_inputs.each_with_index do |input, index|
          decoded[input['name'].to_sym] = values[index]
        end
      end

      decoded
    end

    # 解码topic值
    def decode_topic(topic, type)
      return nil if topic.nil?

      case type
      when 'address'
        # 地址是32字节，取最后20字节
        '0x' + topic[-40..]
      when 'uint256', 'uint128', 'uint64', 'uint32', 'uint16', 'uint8'
        topic.to_i(16)
      when 'int256', 'int128', 'int64', 'int32', 'int16', 'int8'
        # 处理有符号整数
        value = topic.to_i(16)
        bits = type.match(/\d+/)[0].to_i
        max_value = 2**(bits - 1)
        value >= max_value ? value - 2**bits : value
      when 'bool'
        topic.to_i(16) != 0
      when 'bytes32'
        topic
      else
        topic
      end
    end

    # 获取区块时间戳（带缓存）
    def fetch_block_timestamp(block_number_hex)
      return @block_timestamps[block_number_hex] if @block_timestamps[block_number_hex]

      response = perform_request('eth_getBlockByNumber', [block_number_hex, false])

      if response['result'] && response['result']['timestamp']
        timestamp = response['result']['timestamp'].to_i(16)
        @block_timestamps[block_number_hex] = timestamp
        timestamp
      else
        Time.now.to_i
      end
    rescue StandardError => e
      Rails.logger.warn "[NFTContractService] 获取区块时间戳失败: #{e.message}"
      Time.now.to_i
    end
  end
end
