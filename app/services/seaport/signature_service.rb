# frozen_string_literal: true

# Seaport 签名验证服务
#
# 提供 EIP-712 签名验证功能，用于在订单撮合前验证订单签名的有效性。
#
# EIP-712 Domain 参数（已从 Seaport 合约源码验证）：
# - name: "Seaport" (Seaport.sol 第119行)
# - version: "1.6" (ConsiderationBase.sol 第227行)
# - chainId: 从环境变量 CHAIN_ID 获取
# - verifyingContract: 从环境变量 SEAPORT_CONTRACT_ADDRESS 获取
#
module Seaport
  class SignatureService
    class << self
    # TypeHash 常量（延迟计算）
    def eip712_domain_typehash
      @eip712_domain_typehash ||= _keccak256(
        "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
      )
    end

    def order_components_typehash
      @order_components_typehash ||= begin
        order_components_type_string = "OrderComponents(" \
                                       "address offerer," \
                                       "address zone," \
                                       "OfferItem[] offer," \
                                       "ConsiderationItem[] consideration," \
                                       "uint8 orderType," \
                                       "uint256 startTime," \
                                       "uint256 endTime," \
                                       "bytes32 zoneHash," \
                                       "uint256 salt," \
                                       "bytes32 conduitKey," \
                                       "uint256 counter" \
                                       ")"
        consideration_item_type_string = "ConsiderationItem(" \
                                         "uint8 itemType," \
                                         "address token," \
                                         "uint256 identifierOrCriteria," \
                                         "uint256 startAmount," \
                                         "uint256 endAmount," \
                                         "address recipient" \
                                         ")"
        offer_item_type_string = "OfferItem(" \
                                 "uint8 itemType," \
                                 "address token," \
                                 "uint256 identifierOrCriteria," \
                                 "uint256 startAmount," \
                                 "uint256 endAmount" \
                                 ")"
        _keccak256(order_components_type_string + consideration_item_type_string + offer_item_type_string)
      end
    end

    def offer_item_typehash
      @offer_item_typehash ||= _keccak256(
        "OfferItem(" \
        "uint8 itemType," \
        "address token," \
        "uint256 identifierOrCriteria," \
        "uint256 startAmount," \
        "uint256 endAmount" \
        ")"
      )
    end

    def consideration_item_typehash
      @consideration_item_typehash ||= _keccak256(
        "ConsiderationItem(" \
        "uint8 itemType," \
        "address token," \
        "uint256 identifierOrCriteria," \
        "uint256 startAmount," \
        "uint256 endAmount," \
        "address recipient" \
        ")"
      )
    end

    # 验证订单签名
    #
    # @param order [Trading::Order] 订单对象
    # @return [Boolean] 签名是否有效
    #
    def validate_order_signature(order)
      return false if order.signature.blank?
      return false if order.order_hash.blank?

      validate_signature(
        offerer: order.offerer,
        order_hash: order.order_hash,
        signature: order.signature
      )
    end

    # 验证签名（直接参数）
    #
    # @param offerer [String] 订单创建者地址
    # @param order_hash [String] 订单哈希（十六进制字符串或 bytes32）
    # @param signature [String] 签名数据
    # @return [Boolean] 签名是否有效
    #
    def validate_signature(offerer:, order_hash:, signature:)
      # 计算 domain separator
      domain_separator = calculate_domain_separator

      # 计算 EIP-712 digest
      digest = calculate_eip712_digest(domain_separator, order_hash)

      # 验证 ECDSA 签名
      verify_ecdsa_signature(offerer, digest, signature)
    rescue StandardError => e
      Rails.logger.error "[Seaport::SignatureService] 签名验证失败: #{e.message}"
      Rails.logger.error e.backtrace.first(5).join("\n")
      false
    end

    # 验证签名（用于测试，返回详细信息）
    #
    # @param offerer [String] 订单创建者地址
    # @param order_hash [String] 订单哈希
    # @param signature [String] 签名数据
    # @return [Hash] 验证结果 { valid: Boolean, details: String }
    #
    def validate_signature_with_details(offerer:, order_hash:, signature:)
      result = {
        valid: false,
        details: {}
      }

      begin
        # 计算 domain separator
        domain_separator = calculate_domain_separator
        result[:details][:domain_separator] = "0x#{domain_separator.unpack1('H*')}"

        # 计算 EIP-712 digest
        digest = calculate_eip712_digest(domain_separator, order_hash)
        result[:details][:digest] = "0x#{digest.unpack1('H*')}"

        # 解析签名
        parsed_sig = parse_signature(signature)
        result[:details][:signature] = parsed_sig

        # 验证 ECDSA 签名
        recovered_signer = recover_signer(digest, parsed_sig)
        result[:details][:recovered_signer] = recovered_signer
        result[:details][:expected_signer] = offerer.downcase

        if recovered_signer.blank?
          result[:valid] = false
          result[:details][:message] = "签名恢复失败"
          return result
        end

        result[:valid] = recovered_signer.downcase == offerer.downcase

        if result[:valid]
          result[:details][:message] = "签名验证成功"
        else
          result[:details][:message] = "签名验证失败：签名者不匹配"
        end
      rescue StandardError => e
        result[:details][:message] = "签名验证异常: #{e.message}"
        Rails.logger.error "[Seaport::SignatureService] #{e.message}"
      end

      result
    end

    # 计算订单哈希
    #
    # @param order_params [Hash] 订单参数 (来自前端或数据库)
    # @return [String] 订单哈希（十六进制字符串）
    #
    def calculate_order_hash(order_params)
      # 解析订单参数
      offerer = normalize_address(order_params[:offerer] || order_params["offerer"])
      zone = normalize_address(order_params[:zone] || order_params["zone"] || Rails.application.config.x.blockchain.zone_contract_address)
      offer = order_params[:offer] || order_params["offer"] || []
      consideration = order_params[:consideration] || order_params["consideration"] || []
      order_type = (order_params[:orderType] || order_params["orderType"] || order_params[:order_type] || order_params["order_type"] || 2).to_i
      start_time = parse_uint256(order_params[:startTime] || order_params["startTime"] || order_params[:start_time] || order_params["start_time"] || 0)
      end_time = parse_uint256(order_params[:endTime] || order_params["endTime"] || order_params[:end_time] || order_params["end_time"] || Rails.application.config.x.blockchain.seaport_max_uint256)
      zone_hash = order_params[:zoneHash] || order_params["zoneHash"] || order_params[:zone_hash] || order_params["zone_hash"] || "0x0000000000000000000000000000000000000000000000000000000000000000"
      salt = parse_uint256(order_params[:salt] || order_params["salt"] || 0)
      conduit_key = order_params[:conduitKey] || order_params["conduitKey"] || order_params[:conduit_key] || order_params["conduit_key"] || "0x0000000000000000000000000000000000000000000000000000000000000000"
      counter = parse_uint256(order_params[:counter] || order_params["counter"] || 0)

      # 计算 offer items 的哈希
      offer_hash = calculate_array_hash(offer, :offer)

      # 计算 consideration items 的哈希
      consideration_hash = calculate_array_hash(consideration, :consideration)

      zone_hash_bytes = bytes32_from_hex(zone_hash)
      conduit_key_bytes = bytes32_from_hex(conduit_key)

      # 构建订单组件并进行 keccak256 哈希
      order_hash = keccak256_abi(
        %w[bytes32 address address bytes32 bytes32 uint8 uint256 uint256 bytes32 uint256 bytes32 uint256],
        [
          order_components_typehash,
          offerer,
          zone,
          offer_hash,
          consideration_hash,
          order_type,
          start_time,
          end_time,
          zone_hash_bytes,
          salt,
          conduit_key_bytes,
          counter
        ]
      )

      "0x#{order_hash.unpack1('H*')}"
    end

    # 计算 EIP-712 Domain Separator
    #
    # @return [String] Domain Separator（原始字节）
    #
    def calculate_domain_separator
      name = "Seaport"
      version = "1.6"
      chain_id = Rails.application.config.x.blockchain.chain_id
      verifying_contract = Rails.application.config.x.blockchain.seaport_contract_address

      keccak256_abi(
        %w[bytes32 bytes32 bytes32 uint256 address],
        [
          eip712_domain_typehash,
          _keccak256(name),
          _keccak256(version),
          chain_id,
          verifying_contract
        ]
      )
    end

    # 计算 EIP-712 Digest
    #
    # @param domain_separator [String] Domain Separator
    # @param order_hash [String] 订单哈希
    # @return [String] EIP-712 Digest（原始字节）
    #
    def calculate_eip712_digest(domain_separator, order_hash)
      # EIP-712 Message Prefix
      prefix = "\x19\x01"

      # 解析 order_hash（如果是十六进制字符串）
      if order_hash.is_a?(String) && order_hash.start_with?("0x")
        order_hash_bytes = [order_hash[2..]].pack("H*")
      else
        order_hash_bytes = order_hash
      end

      # Digest = keccak256(0x19 || 0x01 || domainSeparator || orderHash)
      _keccak256(prefix + domain_separator + order_hash_bytes)
    end

    # 验证 ECDSA 签名
    #
    # @param signer [String] 预期签名者地址
    # @param digest [String] EIP-712 Digest
    # @param signature [String] 签名数据
    # @return [Boolean] 签名是否有效
    #
    def verify_ecdsa_signature(signer, digest, signature)
      parsed_sig = parse_signature(signature)
      recovered_signer = recover_signer(digest, parsed_sig)
      return false if recovered_signer.blank?

      # 不区分大小写比较地址
      recovered_signer.downcase == normalize_address(signer).downcase
    end

    # 解析签名为 r, s, v
    #
    # @param signature [String] 签名数据
    # @return [Hash] { r: String, s: String, v: Integer }
    #
    def parse_signature(signature)
      # 如果 signature 是十六进制字符串
      if signature.is_a?(String)
        if signature.start_with?("0x")
          sig_bytes = [signature[2..]].pack("H*")
        else
          sig_bytes = [signature].pack("H*")
        end
      else
        sig_bytes = signature
      end

      # 提取 r, s, v
      # 标准 ECDSA 签名: 65 字节 (r: 32 字节, s: 32 字节, v: 1 字节)
      # 或 64 字节 (64 字节签名 + 隐式 v)

      if sig_bytes.length == 65
        r = sig_bytes[0..31]
        s = sig_bytes[32..63]
        v = sig_bytes[64].ord
        compact = false
      elsif sig_bytes.length == 64
        r = sig_bytes[0..31]
        s = sig_bytes[32..63]
        v = nil
        compact = true
      else
        raise "不支持的签名长度: #{sig_bytes.length} 字节"
      end

      { r: r, s: s, v: v, compact: compact }
    end

    # 从 digest 和签名恢复签名者地址
    #
    # @param digest [String] 消息摘要（十六进制字符串或原始字节）
    # @param parsed_sig [Hash] 解析后的签名 { r, s, v }
    # @return [String] 恢复的签名者地址
    #
    def recover_signer(digest, parsed_sig)
      r = parsed_sig[:r]
      s = parsed_sig[:s]
      v = parsed_sig[:v]
      compact = parsed_sig[:compact]

      require 'eth'

      # 确保 digest 是正确的格式
      digest_bytes = if digest.is_a?(String)
        if digest.start_with?("0x")
          [digest[2..]].pack("H*")
        elsif digest.match?(/\A[0-9a-fA-F]{64}\z/)
          [digest].pack("H*")
        else
          digest
        end
      else
        digest
      end

      candidates = []

      if compact
        s_bytes = s.dup
        y_parity = (s_bytes.getbyte(0) & 0x80) >> 7
        s_bytes.setbyte(0, s_bytes.getbyte(0) & 0x7f)
        candidates << { v: 27 + y_parity, s: s_bytes }
        candidates << { v: 27, s: s }
        candidates << { v: 28, s: s }
      else
        v += 27 if v && v <= 1
        candidates << { v: v, s: s }
      end

      candidates.each do |candidate|
        sig_bytes = r + candidate[:s] + [candidate[:v]].pack("C")
        sig_hex = sig_bytes.unpack1("H*")
        pubkey = Eth::Signature.recover(digest_bytes, sig_hex)
        return Eth::Util.public_key_to_address(pubkey).to_s.downcase if pubkey
      end

      nil
    rescue StandardError => e
      Rails.logger.error "[Seaport::SignatureService] recover_signer failed: #{e.message}"
      nil
    end

    # 验证地址格式
    def validate_address(address)
      return false if address.blank?
      return false unless address.match?(/^0x[0-9a-fA-F]{40}$/)
      true
    end

    # 计算数组哈希（用于 Offer[] 和 Consideration[]）
    #
    def calculate_array_hash(items, type)
      return _keccak256("") if items.empty?

      item_hashes = items.map do |item|
        calculate_item_hash(item, type)
      end

      combined = item_hashes.join
      _keccak256(combined)
    end

    # 计算单个 Item 哈希
    #
    def calculate_item_hash(item, type)
      item_type = (item[:itemType] || item["itemType"] || item[:item_type] || item["item_type"] || 0).to_i
      token = normalize_address(item[:token] || item["token"] || item[:Token] || item["Token"])
      identifier = parse_uint256(item[:identifierOrCriteria] || item["identifierOrCriteria"] || item[:identifier] || item["identifier"] || item[:identifier_or_criteria] || item["identifier_or_criteria"] || 0)
      start_amount = parse_uint256(item[:startAmount] || item["startAmount"] || item[:start_amount] || item["start_amount"] || 0)
      end_amount = parse_uint256(item[:endAmount] || item["endAmount"] || item[:end_amount] || item["end_amount"] || 0)

      if type == :offer
        keccak256_abi(
          %w[bytes32 uint8 address uint256 uint256 uint256],
          [offer_item_typehash, item_type, token, identifier, start_amount, end_amount]
        )
      else
        recipient = normalize_address(item[:recipient] || item["recipient"])
        keccak256_abi(
          %w[bytes32 uint8 address uint256 uint256 uint256 address],
          [consideration_item_typehash, item_type, token, identifier, start_amount, end_amount, recipient]
        )
      end
    end

    def keccak256_abi(types, values)
      require 'eth'
      Eth::Util.keccak256(abi_encode(types, values))
    end

    def abi_encode(types, values)
      Blockchain::AbiCoder.new.encode("(#{types.join(',')})", values)
    end

    def bytes32_from_hex(value)
      hex = value.to_s
      hex = hex[2..] if hex.start_with?("0x")
      [hex.rjust(64, "0")].pack("H*")
    end

    # 正确解析 uint256 值（处理 32 字节十六进制字符串）
    def parse_uint256(value)
      str = value.to_s
      if str.start_with?("0x")
        str[2..].to_i(16)
      else
        str.to_i
      end
    end

    # Keccak256 哈希计算（内部使用）
    #
    def _keccak256(*args)
      require 'eth'

      # 将所有参数编码为二进制数据
      binary_data = args.map do |arg|
        case arg
        when String
          if arg.start_with?("0x")
            # 十六进制字符串
            [arg[2..]].pack("H*")
          else
            arg
          end
        when Integer
          # 整数编码为 uint256 (大端序 32 字节)
          [arg].pack("Q>").rjust(32, "\x00")
        when nil
          ""
        else
          arg.to_s
        end
      end.join

      Eth::Util.keccak256(binary_data)
    end

    # 规范化地址
    #
    def normalize_address(address)
      return "0x0000000000000000000000000000000000000000" if address.blank?

      addr = address.to_s.downcase
      addr = addr[2..] if addr.start_with?("0x")
      addr = addr.rjust(40, '0')
      "0x#{addr}"
    end
    end
  end
end
