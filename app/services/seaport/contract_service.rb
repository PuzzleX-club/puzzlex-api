require 'eth'
require 'json'
require 'abi_coder_rb'

module Seaport
  class ContractService

  RATE_LIMIT_INTERVAL = 0.05 # ~20 req/s，低于 QuickNode 25/s 配额

  class RpcError < StandardError; end
  class InvalidResponse < RpcError; end

  def initialize
    # 直接使用constants中定义的RPC URL
    rpc_url = Rails.application.config.x.blockchain.rpc_url
    
    Rails.logger.info "ContractService using RPC: #{rpc_url}" if Rails.env.test?
    
    @client = Eth::Client.create(rpc_url)
    # @contract_abi = Rails.application.config.x.blockchain.seaport_abi
  end

  # 获取最新的区块号
  def latest_block_number
    Rails.logger.debug "[ContractService] 开始获取最新区块号，RPC: #{Rails.application.config.x.blockchain.rpc_url}"
    
    payload = {
      jsonrpc: "2.0",
      method: "eth_blockNumber",
      params: [],
      id: 1
    }.to_json

    Rails.logger.debug "[ContractService] 发送请求: #{payload}"
    
    response = perform_request(payload)
    Rails.logger.debug "[ContractService] 原始响应: #{response}"
    
    parsed_response = JSON.parse(response)

    if parsed_response["result"]
      hex_value = parsed_response["result"]
      decimal_value = hex_value.to_i(16) # 转换为十进制
      Rails.logger.info "[ContractService] 获取到区块号: #{hex_value} (十进制: #{decimal_value})"
      decimal_value
    else
      Rails.logger.error "[ContractService] 获取区块号失败: #{parsed_response['error']}"
      Rails.logger.error "[ContractService] 完整响应: #{parsed_response.inspect}"
      nil
    end
  rescue => e
    Rails.logger.error "[ContractService] 获取区块号异常: #{e.class.name} - #{e.message}"
    Rails.logger.error "[ContractService] Backtrace: #{e.backtrace.first(5).join("\n")}"
    nil
  end

  # 从链上获取订单状态
  def get_order_status(order_hash)
    # 从 ABI 获取 `getOrderStatus` 函数的定义
    function = Rails.application.config.x.blockchain.seaport_abi.find { |f| f["name"] == "getOrderStatus" }
    raise "Method ABI not found" unless function

    # 生成方法选择器（4字节的哈希前缀）
    function_signature = "getOrderStatus(bytes32)"
    method_selector = Eth::Util.keccak256(function_signature)[0, 4].unpack1("H*") # 转换为十六进制字符串

    # 编码参数 `order_hash` 并将方法选择器添加到前面
    # 1. 将 order_hash 确保转换为字符串
    order_hash_str = order_hash.to_s

    # 2. 确保去除前缀 "0x" 并补足 64 位
    encoded_order_hash = order_hash_str.start_with?("0x") ? order_hash_str[2..] : order_hash_str
    encoded_order_hash = encoded_order_hash.rjust(64, '0')

    data = "0x#{method_selector}#{encoded_order_hash}"

    # 构建 JSON-RPC 请求，注意需要包装成json
    payload = {
      jsonrpc: "2.0",
      method: "eth_call",
      params: [{
                 to: Rails.application.config.x.blockchain.seaport_contract_address,
                 data: data
               }, "latest"],
      id: 1
    }.to_json
    
    # 发送请求并解析结果
    response = perform_request(payload)
    result = JSON.parse(response)["result"]

    if result && result != "0x" # 确保 result 有效
      # 定义输出类型并解码
      parse_order_status(result)
    else
      { error: "Invalid response or empty result" }
    end
  rescue => e
    Rails.logger.error "Error calling getOrderStatus: #{e.message}"
    { error: "Failed to retrieve order status" }
  end

  # 获取链上事件，OrderValidated，OrderFulfilled，OrdersMatched
  def get_event_logs(event_name:"OrderFulfilled", from_block: "earliest", to_block: "latest", topics: [])
    # 确保 from_block 和 to_block 是十六进制字符串
    from_block_hex = "0x" + from_block.to_i.to_s(16) if from_block.is_a?(Integer)
    to_block_hex = "0x" + to_block.to_i.to_s(16) if to_block.is_a?(Integer)

    # 从 ABI 获取指定事件的定义
    event = Rails.application.config.x.blockchain.seaport_abi.find { |e| e["type"] == "event" && e["name"] == event_name }
    raise "Event ABI not found" unless event

    # 生成事件的 topic（事件的哈希值）
    event_signature = "#{event['name']}(" +
      event['inputs'].map { |input| format_input_type(input) }.join(",") +
      ")"

    # puts "Event Signature: #{event_signature}"
    event_topic = "0x" + Eth::Util.keccak256(event_signature).unpack1("H*")
    # puts "Event Topic: #{event_topic}"

    # 构建 JSON-RPC 请求
    payload = {
      jsonrpc: "2.0",
      method: "eth_getLogs",
      params: [{
                 fromBlock: from_block_hex || from_block, # 使用十六进制或默认值
                 toBlock: to_block_hex || to_block,     # 使用十六进制或默认值
                 address: Rails.application.config.x.blockchain.seaport_contract_address, # 合约地址
                 topics: [event_topic, *topics] # 事件 topic 和额外过滤条件
               }],
      id: 1
    }.to_json
    puts payload

    # 发送请求并解析结果
    response = perform_request(payload)

    parsed = JSON.parse(response)
    if parsed["error"]
      raise RpcError, parsed["error"].inspect
    end

    result_rep = parsed["result"]

    decoded_logs = [] # 用于存储解码后的日志

    Rails.logger.info "📊 收到 #{event_name} 事件查询结果：#{result_rep&.length || 0} 个事件"
    
    if result_rep && result_rep.is_a?(Array)
      result_rep.each_with_index do |log, index|
        begin
          Rails.logger.info "🔄 处理第 #{index + 1}/#{result_rep.length} 个 #{event_name} 事件"
          
          # 确保每个 log 是哈希类型，并包含 "data" 和 "topics"
          unless log.is_a?(Hash) && log.key?("data") && log.key?("topics")
            Rails.logger.warn "❌ 跳过无效日志格式 (第 #{index + 1} 个): #{log.inspect}"
            
            # 仍然添加到结果中，但标记为无效
            invalid_log = log.is_a?(Hash) ? log.dup : { "raw_data" => log }
            invalid_log[:decode_failed] = true
            invalid_log[:decode_error] = "Invalid log format: missing data or topics"
            invalid_log[:event_name] = event_name
            decoded_logs << invalid_log
            next
          end

          Rails.logger.info "🔍 开始解析事件 #{event_name}，交易哈希: #{log['transactionHash']}"
          Rails.logger.debug "📋 事件输入定义: #{event['inputs'].inspect}"
          Rails.logger.debug "📄 原始日志数据: topics=#{log['topics'].inspect}, data=#{log['data']}"

          inputs = event["inputs"]

          decoded_log = decode_event_log(inputs, log)
          
          Rails.logger.info "✅ 事件解析成功: #{decoded_log.inspect}"

          decoded_logs << decoded_log.merge(
            transaction_hash: log["transactionHash"],
            log_index: log["logIndex"],
            block_number: log["blockNumber"]&.to_i(16), # 提取区块号
            block_timestamp: fetch_block_timestamp(log["blockNumber"]) # 提取区块时间戳
          )

          # Rails.logger.info "Decoded: #{decoded.inspect}"
        rescue => e
          Rails.logger.error "❌ Error decoding log for #{event_name}: #{e.message}"
          Rails.logger.error "📄 Failed log data: #{log.inspect}"
          Rails.logger.error "🔍 Backtrace: #{e.backtrace.first(5).join("\n")}"
          
          # 解析失败时，为了调试目的，我们添加一个标记了失败状态的原始数据
          # 这样可以在 EventListener 中进行进一步的手动处理
          failed_log = log.dup
          failed_log[:decode_failed] = true
          failed_log[:decode_error] = e.message
          failed_log[:event_name] = event_name
          
          decoded_logs << failed_log.merge(
            transaction_hash: log["transactionHash"],
            log_index: log["logIndex"],
            block_number: log["blockNumber"]&.to_i(16),
            block_timestamp: fetch_block_timestamp(log["blockNumber"])
          )
          
          Rails.logger.warn "⚠️ Added failed log to results for manual processing"
        end
      end
    else
      raise InvalidResponse, "无效的查询结果格式 (#{event_name}): #{result_rep.inspect}"
    end

    decoded_logs
  rescue => e
    Rails.logger.error "Error fetching event logs: #{e.message}, backtrace: #{e.backtrace.join("\n")}"
    raise
  end

  # 对外暴露的通用日志解码（供统一 collector 使用）
  def decode_raw_log(log, event_name:)
    event = Rails.application.config.x.blockchain.seaport_abi.find { |e| e["type"] == "event" && e["name"] == event_name }
    raise "Event ABI not found: #{event_name}" unless event

    decoded = decode_event_log(event["inputs"], log)
    decoded.merge(
      event_name: event_name,
      transaction_hash: log["transactionHash"],
      log_index: log["logIndex"].is_a?(String) ? log["logIndex"].to_i(16) : log["logIndex"],
      block_number: log["blockNumber"]&.to_i(16),
      block_timestamp: fetch_block_timestamp(log["blockNumber"])
    )
  end

  private

  # 解析链上validate方法返回的订单状态
  def parse_order_status(result)
    return { error: "Invalid response or empty result" } if result.nil? || result == "0x"

    # 去除开头的 "0x"
    data = result[2..-1]

    # 按字节位置解析：
    # is_validated: bool -> 第一个 32 字节中只有最后一位决定bool值
    # is_cancelled: bool -> 第二个32字节
    # total_filled, total_size: uint256

    # 按字段位置解析
    raw_validated = data[0, 64].to_i(16)
    raw_cancelled = data[64, 64].to_i(16)
    total_filled = data[128, 64].to_i(16)
    total_size = data[192, 64].to_i(16)

    {
      is_validated: (raw_validated == 1),
      is_cancelled: (raw_cancelled == 1),
      total_filled: total_filled,
      total_size: total_size
    }
  end

  # 递归格式化输入类型，获取函数签名
  def format_input_type(input)
    if input["type"] == "tuple" && input["components"]
      # 如果是 tuple，则递归处理其 components
      "(" + input["components"].map { |comp| format_input_type(comp) }.join(",") + ")"
    elsif input["type"].include?("tuple") && input["type"].end_with?("[]")
      # 如果是数组类型的 tuple
      "(" + input["components"].map { |comp| format_input_type(comp) }.join(",") + ")[]"
    else
      input["type"] # 普通类型直接返回
    end
  end

  # 解析事件日志
  def decode_event_log(inputs,log)
    # 处理 topics 中的 indexed 参数
    indexed_inputs = inputs.select { |input| input["indexed"] }
    non_indexed_inputs = inputs.reject { |input| input["indexed"] }

    # 解码 topics 中的 indexed 参数
    indexed_decoded = {}
    if indexed_inputs.any?
      log["topics"][1..].each_with_index do |topic, index|
        input = indexed_inputs[index]
        indexed_decoded[input["name"]] = decode_topic(topic, input["type"])
      end
    end

    # 解码 data 中的非 indexed 参数
    data = log["data"][2..] # 去除 "0x"
    non_indexed_types = non_indexed_inputs.map { |input| format_input_type(input)  }
    
    Rails.logger.debug "🔍 AbiCoder 解析调试信息:"
    Rails.logger.debug "📋 非indexed字段: #{non_indexed_inputs.map{|i| i['name']}.inspect}"
    Rails.logger.debug "📋 类型字符串: #{non_indexed_types.inspect}"
    Rails.logger.debug "📋 组合类型: (#{non_indexed_types.join(',')})"
    Rails.logger.debug "📄 Data 长度: #{data.length} characters"
    Rails.logger.debug "📄 Data 前100字符: #{data[0..99]}"
    
    begin
      non_indexed_decoded = ::Blockchain::AbiCoder.new.decode_data("(" + non_indexed_types.join(",") + ")", data)
      Rails.logger.debug "✅ AbiCoder 解析成功: #{non_indexed_decoded.inspect}"
    rescue => decode_error
      Rails.logger.error "❌ AbiCoder 解析失败: #{decode_error.message}"
      Rails.logger.error "🔍 解析错误堆栈: #{decode_error.backtrace.first(3).join("\n")}"
      raise decode_error
    end

    # 保留字段顺序：将 decoded 字段与 inputs 对齐
    decoded = inputs.map do |input|
      if input["indexed"]
        indexed_decoded[input["name"]]
      else
        non_indexed_decoded.shift
      end
    end

    decoded = normalize_decoded_data(decoded)
    wrap_decoded_with_names(decoded, inputs, true)
  end

  # 解析bytes32类型的数据
  def normalize_decoded_data(data)
    if data.is_a?(Array)
      # 如果是数组，递归解析每一项
      data.map { |item| normalize_decoded_data(item) }
    elsif data.is_a?(Hash)
      # 如果是哈希，递归解析值
      data.transform_values { |value| normalize_decoded_data(value) }
    elsif data.is_a?(String)
      # 如果是字符串，尝试解码为可读形式
      binary_regex = Regexp.new("[\x00-\x1F\x7F-\xFF]".force_encoding("ASCII-8BIT"))

      if data.encoding.name == "ASCII-8BIT" || data.match?(binary_regex)
        # 转为十六进制字符串并添加 0x 前缀
        "0x#{data.unpack1('H*')}"
      else
        # 对于普通的十六进制字符串，确保有 0x 前缀
        if data.match?(/\A[0-9a-f]+\z/i) && data.length >= 40 # 地址或哈希
          "0x#{data}"
        else
          data
        end
      end
    elsif data.is_a?(Numeric)
      # 保留数值
      data
    else
      # 默认直接返回
      data
    end
  end

  def wrap_decoded_with_names(decoded, abi, root_level = false)
    if abi.is_a?(Array)
      # 如果 ABI 是数组，逐一递归处理每个元素
      if root_level
        # 如果是顶层数组，将其转化为以 name 为键的哈希
        Hash[
          abi.map.with_index do |item_abi, index|
            [item_abi["name"].to_sym, wrap_decoded_with_names(decoded[index], item_abi)]
          end
        ]
      else
        # 非顶层数组，逐一递归处理每个元素
        decoded.each_with_index.map do |item, index|
          wrap_decoded_with_names(item, abi[index % abi.size])
        end
      end
    elsif abi.is_a?(Hash)
      if abi["type"] == "tuple"
        # 处理 tuple 类型
        Hash[
          abi["components"].map.with_index do |component, index|
            [component["name"].to_sym, wrap_decoded_with_names(decoded[index], component)]
          end
        ]
      elsif abi["type"].end_with?("[]")
        # 动态数组类型，处理每个数组元素
        element_abi = abi.dup
        element_abi["type"] = abi["type"].chomp("[]")
        decoded.map { |item| wrap_decoded_with_names(item, element_abi) }
      else
        # 基础类型：如果在根级别直接返回哈希，否则避免重复嵌套
        root_level ? { abi["name"].to_sym => decoded } : decoded
      end
    else
      # 非数组或哈希类型直接返回
      decoded
    end
  end

  def decode_topic(topic, type)
    case type
    when "address"
      "0x#{topic[26..]}" # 添加 0x 前缀
    when "uint256", "int256"
      topic.to_i(16)
    when "bytes32"
      topic # bytes32 已经包含 0x 前缀
    else
      raise "Unsupported indexed type: #{type}"
    end
  end

  def fetch_block_timestamp(block_number)
    return nil unless block_number

    payload = {
      jsonrpc: "2.0",
      method: "eth_getBlockByNumber",
      params: [block_number, false],
      id: 1
    }.to_json

    response = perform_request(payload)
    parsed_response = JSON.parse(response)
    if parsed_response["error"]
      raise RpcError, parsed_response["error"].inspect
    end

    block_data = parsed_response["result"]
    block_data ? block_data["timestamp"].to_i(16) : nil
  rescue => e
    Rails.logger.error "Error fetching block timestamp: #{e.message}"
    nil
  end

  def perform_request(payload)
    self.class.throttle!
    @client.send_request(payload)
  end

  def self.throttle!
    rate_limit_mutex.synchronize do
      current = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      wait = RATE_LIMIT_INTERVAL - (current - last_request_time)
      sleep(wait) if wait.positive?
      @last_request_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end

  def self.rate_limit_mutex
    @rate_limit_mutex ||= Mutex.new
  end

  def self.last_request_time
    @last_request_time ||= 0.0
  end
end
end
