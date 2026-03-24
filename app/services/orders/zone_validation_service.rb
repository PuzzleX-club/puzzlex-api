# frozen_string_literal: true

# Zone 验证服务
#
# 从配置文件/环境变量获取 Zone 限制并验证订单：
# 1. Token 类型限制（ERC1155 + NATIVE/指定 ERC20）
# 2. 费用要求（平台费 + 版税费）
# 3. 指定地址限制（Offer 类型）
#
class Orders::ZoneValidationService
  # Seaport ItemType 常量
  ItemType = {
    NATIVE: 0,
    ERC20: 1,
    ERC721: 2,
    ERC1155: 3,
    ERC721_WITH_CRITERIA: 4,
    ERC1155_WITH_CRITERIA: 5
  }.freeze

  attr_reader :zone_address, :errors, :validation_details

  def initialize(zone_address = nil)
    @zone_address = zone_address || Rails.application.config.x.blockchain.zone_contract_address
    @errors = []
    @validation_details = {}
    @zone_config = Rails.application.config.x.zone_validation
  end

  # 验证订单是否满足 Zone 限制
  #
  # @param order_params [Hash] 订单参数
  # @param user_address [String] 用户地址（用于验证 specifiedAddresses）
  # @return [Hash] { success: Boolean, errors: Array, details: Hash }
  #
  def validate(order_params, user_address = nil)
    @errors = []
    @validation_details = {
      step: nil,
      passed_steps: [],
      failed_steps: [],
      zone_address: @zone_address,
      order_type: nil,
      offer_item_types: [],
      consideration_item_types: [],
      fees_valid: nil,
      specified_address_valid: nil
    }

    # 步骤 1: 验证 Token 类型
    step1_passed = validate_token_types(order_params)
    return { success: false, errors: @errors, details: @validation_details } unless step1_passed

    # 步骤 2: 验证费用
    step2_passed = validate_fees(order_params)
    return { success: false, errors: @errors, details: @validation_details } unless step2_passed

    # 步骤 3: 验证指定地址（仅 Offer 类型）
    step3_passed = validate_specified_address(order_params, user_address)
    return { success: false, errors: @errors, details: @validation_details } unless step3_passed

    @validation_details[:step] = :all_passed
    @validation_details[:passed_steps] = [:token_types_valid, :fees_valid, :specified_address_valid]

    Rails.logger.info "[ZoneValidationService] Zone 验证全部通过: zone=#{@zone_address}"

    { success: true, errors: [], details: @validation_details }
  end

  # 快速验证（仅返回 Boolean）
  #
  def valid?(order_params, user_address = nil)
    result = validate(order_params, user_address)
    result[:success]
  end

  private

  # 验证 Token 类型
  def validate_token_types(order_params)
    @validation_details[:step] = :token_types_valid

    offer = order_params[:offer] || order_params["offer"] || []
    consideration = order_params[:consideration] || order_params["consideration"] || []

    # 统计各类 Token
    offer_item_types = offer.map { |item| item[:itemType] || item["itemType"] }
    consideration_item_types = consideration.map { |item| item[:itemType] || item["itemType"] }

    @validation_details[:offer_item_types] = offer_item_types
    @validation_details[:consideration_item_types] = consideration_item_types

    # 检查 ERC1155 数量
    offer_erc1155_count = offer_item_types.count { |t| [ItemType[:ERC1155], ItemType[:ERC1155_WITH_CRITERIA]].include?(t.to_i) }
    consideration_erc1155_count = consideration_item_types.count { |t| [ItemType[:ERC1155], ItemType[:ERC1155_WITH_CRITERIA]].include?(t.to_i) }

    # 规则 1: 两侧不能同时有 ERC1155
    if offer_erc1155_count > 0 && consideration_erc1155_count > 0
      @errors << "订单无效：Offer 和 Consideration 不能同时包含 ERC1155"
      @validation_details[:failed_steps] << :token_types_valid
      Rails.logger.warn "[ZoneValidationService] 无效：两侧同时包含 ERC1155"
      return false
    end

    # 规则 2: ERC1155 数量不能超过 1
    if offer_erc1155_count > 1
      @errors << "订单无效：Offer 中 ERC1155 数量超过 1 个"
      @validation_details[:failed_steps] << :token_types_valid
      return false
    end

    if consideration_erc1155_count > 1
      @errors << "订单无效：Consideration 中 ERC1155 数量超过 1 个"
      @validation_details[:failed_steps] << :token_types_valid
      return false
    end

    # 规则 3: 确定订单类型并验证非 ERC1155 侧的 Token 类型
    # 根据 Seaport 协议：
    # - 买单（Offer）：offer 是支付（ETH/ERC20），consideration 是 NFT（ERC1155）
    # - 卖单（List）：offer 是 NFT（ERC1155），consideration 是支付（ETH/ERC20）
    if consideration_erc1155_count > 0
      # Consideration 类型（买单）
      @validation_details[:order_type] = :offer
      valid, error = validate_non_erc1155_side(consideration_item_types, consideration, :consideration)
      return false unless valid
    elsif offer_erc1155_count > 0
      # Offer 类型（卖单）
      @validation_details[:order_type] = :list
      valid, error = validate_non_erc1155_side(offer_item_types, offer, :offer)
      return false unless valid
    else
      @errors << "订单无效：必须包含 ERC1155"
      @validation_details[:failed_steps] << :token_types_valid
      return false
    end

    @validation_details[:passed_steps] << :token_types_valid
    Rails.logger.info "[ZoneValidationService] 步骤通过: Token 类型验证通过, order_type=#{@validation_details[:order_type]}"
    true
  end

  # 验证非 ERC1155 侧（只能是 NATIVE 或指定的 ERC20，且不能混合）
  def validate_non_erc1155_side(item_types, items, side)
    has_native = item_types.include?(ItemType[:NATIVE])
    has_erc20 = item_types.include?(ItemType[:ERC20])

    # 不能同时有 NATIVE 和 ERC20
    if has_native && has_erc20
      error_msg = "订单无效：#{side} 侧不能同时包含 NATIVE 和 ERC20"
      @errors << error_msg
      @validation_details[:failed_steps] << :token_types_valid
      Rails.logger.warn "[ZoneValidationService] #{error_msg}"
      return [false, error_msg]
    end

    # 如果有 ERC20，必须是指定的 Token
    if has_erc20
      erc20_items = items.select { |item| [ItemType[:ERC20], ItemType[:ERC721_WITH_CRITERIA], ItemType[:ERC1155_WITH_CRITERIA]].include?(item[:itemType].to_i) }
      erc20_items.each do |item|
        token = item[:token] || item["token"]
        token = token.downcase.sub(/^0x/, '') if token.is_a?(String)
        allowed_tokens = @zone_config[:specified_erc20_tokens].map { |t| t.downcase.sub(/^0x/, '') }.reject(&:blank?)
        next if allowed_tokens.empty?  # 如果没有配置，允许任何 ERC20

        unless allowed_tokens.include?(token)
          @errors << "订单无效：ERC20 Token #{item[:token]} 不在 Zone 允许列表中"
          @validation_details[:failed_steps] << :token_types_valid
          Rails.logger.warn "[ZoneValidationService] ERC20 Token 不在允许列表中: #{item[:token]}"
          return [false, "invalid erc20 token"]
        end
      end
    end

    [true, nil]
  end

  # 验证费用
  def validate_fees(order_params)
    @validation_details[:step] = :fees_valid

    order_type = @validation_details[:order_type]
    items = order_type == :offer ? order_params[:offer] : order_params[:consideration]
    items = items || []

    # List 类型必须正好 3 个 consideration
    # Offer 类型必须正好 3 个 offer
    if items.length != 3
      @errors << "订单无效：#{order_type == :offer ? 'Offer' : 'Consideration'} 必须正好 3 个"
      @validation_details[:failed_steps] << :fees_valid
      Rails.logger.warn "[ZoneValidationService] #{order_type} items 数量不为 3: #{items.length}"
      return false
    end

    # 解析金额
    amounts = items.map do |item|
      parse_uint256(
        value_of(item, :amount) ||
        value_of(item, :startAmount) ||
        value_of(item, :endAmount)
      )
    end
    net_amount, plat_amount, roy_amount = amounts

    total = net_amount + plat_amount + roy_amount

    # 计算期望费用
    expected_platform_fee = (total * @zone_config[:platform_fee_percentage]) / 10000
    expected_royalty_fee = (total * @zone_config[:royalty_fee_percentage]) / 10000

    @validation_details[:fees] = {
      net_amount: net_amount,
      platform_amount: plat_amount,
      royalty_amount: roy_amount,
      total: total,
      expected_platform_fee: expected_platform_fee,
      expected_royalty_fee: expected_royalty_fee
    }

    # 验证平台费
    if plat_amount < expected_platform_fee
      @errors << "平台费不足：期望 >= #{expected_platform_fee}, 实际 = #{plat_amount}"
      @validation_details[:failed_steps] << :fees_valid
      Rails.logger.warn "[ZoneValidationService] 平台费不足: expected=#{expected_platform_fee}, actual=#{plat_amount}"
      return false
    end

    # 验证版税费
    if roy_amount < expected_royalty_fee
      @errors << "版税费不足：期望 >= #{expected_royalty_fee}, 实际 = #{roy_amount}"
      @validation_details[:failed_steps] << :fees_valid
      Rails.logger.warn "[ZoneValidationService] 版税费不足: expected=#{expected_royalty_fee}, actual=#{roy_amount}"
      return false
    end

    # 验证收款方（仅 List 类型）
    if order_type == :list
      consideration = order_params[:consideration] || order_params["consideration"] || []
      platform_recipient = value_of(consideration[1], :recipient)&.downcase
      royalty_recipient = value_of(consideration[2], :recipient)&.downcase

      if platform_recipient != @zone_config[:platform_fee_recipient].downcase
        @errors << "平台费收款方错误"
        @validation_details[:failed_steps] << :fees_valid
        return false
      end
      if royalty_recipient != @zone_config[:royalty_fee_recipient].downcase
        @errors << "版税收款方错误"
        @validation_details[:failed_steps] << :fees_valid
        return false
      end
    end

    @validation_details[:passed_steps] << :fees_valid
    Rails.logger.info "[ZoneValidationService] 步骤通过: 费用验证通过"
    true
  end

  # 验证指定地址（仅 Offer 类型）
  def validate_specified_address(order_params, user_address)
    @validation_details[:step] = :specified_address_valid

    # 只有 Offer 类型需要验证
    return true unless @validation_details[:order_type] == :offer

    # 如果没有配置 specifiedAddresses，跳过验证
    return true if @zone_config[:specified_addresses].empty?

    if user_address.blank?
      @errors << "Offer 类型订单需要验证指定地址，但未提供用户地址"
      @validation_details[:failed_steps] << :specified_address_valid
      return false
    end

    # 检查用户地址是否在 specifiedAddresses 中
    user_address_normalized = user_address.downcase.sub(/^0x/, '')
    specified_addresses_normalized = @zone_config[:specified_addresses].map { |a| a.downcase.sub(/^0x/, '') }

    is_specified = specified_addresses_normalized.include?(user_address_normalized)
    @validation_details[:specified_address_valid] = is_specified

    unless is_specified
      @errors << "用户地址不是 Zone 指定的地址"
      @validation_details[:failed_steps] << :specified_address_valid
      Rails.logger.warn "[ZoneValidationService] 用户地址不是指定地址: #{user_address}"
      return false
    end

    @validation_details[:passed_steps] << :specified_address_valid
    Rails.logger.info "[ZoneValidationService] 步骤通过: 指定地址验证通过"
    true
  end

  # 解析 uint256 值
  def parse_uint256(value)
    return 0 if value.blank?
    str = value.to_s
    if str.start_with?("0x")
      str[2..].to_i(16)
    else
      str.to_i
    end
  end

  def value_of(item, key)
    return nil if item.nil?
    item[key] || item[key.to_s]
  end
end
