require 'faraday'

module Blockchain
  class RpcService
    # 方法选择器
    BALANCE_OF_SELECTOR = '00fdd58e'  # ERC1155 balanceOf(address,uint256)
    BALANCE_OF_ERC20_SELECTOR = '70a08231'  # ERC20 balanceOf(address)
    ALLOWANCE_SELECTOR = 'dd62ed3e'  # ERC20 allowance(address,address)
    IS_APPROVED_FOR_ALL_SELECTOR = 'e985e9c5'  # ERC1155 isApprovedForAll(address,address)

    def initialize(rpc_url:, chain_id: nil)
      @chain_id = chain_id
      @node_url = rpc_url
      @network_name = chain_id.present? ? "chain_#{chain_id}" : "configured"

      @connection = Faraday.new(url: @node_url) do |faraday|
        faraday.request :json
        faraday.response :json
        faraday.adapter Faraday.default_adapter
        faraday.options.timeout = 10  # 10秒超时
        faraday.options.open_timeout = 5
      end
    end

    # 工厂方法 - 根据环境自动选择网络
    def self.for_current_environment
      blockchain_config = Rails.application.config.x.blockchain
      rpc_url = blockchain_config.rpc_url
      chain_id = blockchain_config.chain_id

      if rpc_url.present?
        Rails.logger.info "[RPC] 使用环境配置: rpc_url=#{rpc_url}, chain_id=#{chain_id}"
        return new(rpc_url: rpc_url, chain_id: chain_id)
      end

      raise "RPC URL 未配置！请在 Rails 环境中设置 config.x.blockchain.rpc_url。\n" \
            "当前 Rails.env: #{Rails.env}\n" \
            "当前 blockchain 配置: #{blockchain_config.to_h.inspect}"
    end

    # 获取NFT余额 (ERC1155)
    def get_nft_balance(wallet_address, token_id)
      begin
        data = build_balance_of_data(wallet_address, token_id)
        nft_contract = Rails.application.config.x.blockchain.nft_contract_address

        Rails.logger.debug "[RPC] #{@network_name} 查询NFT余额: address=#{wallet_address}, tokenId=#{token_id}, contract=#{nft_contract}"

        result = send_request('eth_call', [{
          to: nft_contract.downcase,
          data: "0x#{data}"
        }, 'latest'])

        balance = result.first.to_i
        Rails.logger.debug "[RPC] #{@network_name} NFT余额结果: #{balance}"
        balance
      rescue => e
        Rails.logger.error "[RPC] #{@network_name} 获取NFT余额失败: #{e.message}"
        raise RpcServiceError, e.message
      end
    end

    # 获取ERC20余额
    def get_erc20_balance(token_address, wallet_address)
      begin
        data = build_balance_of_erc20_data(wallet_address)

        Rails.logger.debug "[RPC] #{@network_name} 查询ERC20余额: address=#{wallet_address}, token=#{token_address}"

        result = send_request('eth_call', [{
          to: token_address.downcase,
          data: "0x#{data}"
        }, 'latest'])

        balance = result.first.to_i
        Rails.logger.debug "[RPC] #{@network_name} ERC20余额结果: #{balance}"
        balance
      rescue => e
        Rails.logger.error "[RPC] #{@network_name} 获取ERC20余额失败: #{e.message}"
        raise RpcServiceError, e.message
      end
    end

    # 获取ERC20授权额度
    def get_erc20_allowance(token_address, owner_address, spender_address)
      begin
        data = build_allowance_data(owner_address, spender_address)

        Rails.logger.debug "[RPC] #{@network_name} 查询ERC20授权: owner=#{owner_address}, spender=#{spender_address}, token=#{token_address}"

        result = send_request('eth_call', [{
          to: token_address.downcase,
          data: "0x#{data}"
        }, 'latest'])

        allowance = result.first.to_i
        Rails.logger.debug "[RPC] #{@network_name} ERC20授权结果: #{allowance}"
        allowance
      rescue => e
        Rails.logger.error "[RPC] #{@network_name} 获取ERC20授权失败: #{e.message}"
        raise RpcServiceError, e.message
      end
    end

    # 获取ERC1155授权状态
    def get_erc1155_approval(nft_contract_address, owner_address, operator_address)
      begin
        data = build_is_approved_for_all_data(owner_address, operator_address)

        Rails.logger.debug "[RPC] #{@network_name} 查询ERC1155授权: owner=#{owner_address}, operator=#{operator_address}, contract=#{nft_contract_address}"

        result = send_request('eth_call', [{
          to: nft_contract_address.downcase,
          data: "0x#{data}"
        }, 'latest'])

        approved = result.first.to_i == 1
        Rails.logger.debug "[RPC] #{@network_name} ERC1155授权结果: #{approved}"
        approved
      rescue => e
        Rails.logger.error "[RPC] #{@network_name} 获取ERC1155授权失败: #{e.message}"
        raise RpcServiceError, e.message
      end
    end

    # 获取原生代币余额
    def get_native_balance(wallet_address)
      begin
        Rails.logger.debug "[RPC] #{@network_name} 查询原生代币余额: address=#{wallet_address}"

        result = send_request('eth_getBalance', [wallet_address.downcase, 'latest'])
        balance = result.first.to_i

        Rails.logger.debug "[RPC] #{@network_name} 原生代币余额结果: #{balance}"
        balance
      rescue => e
        Rails.logger.error "[RPC] #{@network_name} 获取原生代币余额失败: #{e.message}"
        raise RpcServiceError, e.message
      end
    end

    # 根据代币地址获取余额（智能选择）
    def get_balance_by_address(token_address, wallet_address)
      if token_address.nil? || token_address == '0x0000000000000000000000000000000000000000' ||
         token_address.downcase == '0x0' || token_address.downcase == '0x0000000000000000000000000000000000000000'
        get_native_balance(wallet_address)
      else
        get_erc20_balance(token_address, wallet_address)
      end
    end

    private

    def send_request(method, params = [])
      @last_request_id = rand(1..10000)
      request_body = {
        jsonrpc: "2.0",
        method: method,
        params: params,
        id: @last_request_id
      }

      response = @connection.post do |req|
        req.headers['Content-Type'] = 'application/json'
        req.body = request_body.to_json
      end

      process_response(response.body)
    end

    # 构建ERC1155 balanceOf调用数据
    def build_balance_of_data(wallet_address, token_id)
      # 移除 0x 前缀并转换为小写
      clean_address = wallet_address.gsub(/^0x/i, '').downcase.rjust(64, '0')
      # 转换token_id为16进制并填充到64位
      clean_token_id = token_id.to_i.to_s(16).rjust(64, '0')

      "#{BALANCE_OF_SELECTOR}#{clean_address}#{clean_token_id}"
    end

    # 构建ERC20 balanceOf调用数据
    def build_balance_of_erc20_data(wallet_address)
      # 移除 0x 前缀并转换为小写
      clean_address = wallet_address.gsub(/^0x/i, '').downcase.rjust(64, '0')

      "#{BALANCE_OF_ERC20_SELECTOR}#{clean_address}"
    end

    # 构建ERC20 allowance调用数据
    def build_allowance_data(owner_address, spender_address)
      clean_owner = owner_address.gsub(/^0x/i, '').downcase.rjust(64, '0')
      clean_spender = spender_address.gsub(/^0x/i, '').downcase.rjust(64, '0')

      "#{ALLOWANCE_SELECTOR}#{clean_owner}#{clean_spender}"
    end

    # 构建ERC1155 isApprovedForAll调用数据
    def build_is_approved_for_all_data(owner_address, operator_address)
      clean_owner = owner_address.gsub(/^0x/i, '').downcase.rjust(64, '0')
      clean_operator = operator_address.gsub(/^0x/i, '').downcase.rjust(64, '0')

      "#{IS_APPROVED_FOR_ALL_SELECTOR}#{clean_owner}#{clean_operator}"
    end

    def process_response(response_body)
      if response_body['error']
        error_msg = response_body['error']['message'] || 'Unknown RPC error'
        Rails.logger.error "[RPC] #{@network_name} 错误: #{error_msg}"
        raise RpcServiceError, "RPC Error: #{error_msg}"
      end

      unless response_body["id"] == @last_request_id
        Rails.logger.error "[RPC] #{@network_name} 响应ID不匹配: 期望#{@last_request_id}, 收到#{response_body["id"]}"
        raise RpcServiceError, "Invalid response ID"
      end

      hex_data = response_body["result"]
      return [0] if hex_data.nil? || hex_data.empty?

      # 移除 "0x" 前缀并转换为整数
      clean_data = hex_data.gsub(/^0x/i, '')
      [clean_data.to_i(16)]
    rescue RpcServiceError
      raise
    rescue StandardError => e
      Rails.logger.error "[RPC] #{@network_name} 处理响应失败: #{e.message}"
      raise RpcServiceError, e.message
    end
  end
end
