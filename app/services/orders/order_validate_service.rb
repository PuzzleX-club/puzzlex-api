# frozen_string_literal: true

# 订单验证服务
#
# 在创建订单前验证：
# 1. 用户地址与订单 offerer 一致
# 2. 计算的 order_hash 与传入的 order_hash 一致
# 3. 签名恢复的地址与用户地址一致
# 4. Zone 限制检查（Token 类型、费用、指定地址）
#
class Orders::OrderValidateService
  attr_reader :user, :order_params, :errors, :validation_details

  def initialize(user, order_params, chain_id = nil)
    @user = user
    @order_params = order_params
    @chain_id = chain_id
    @errors = []
    @validation_details = {}
  end

  # 验证订单
  #
  # @return [Hash] { success: Boolean, errors: Array, details: Hash }
  #
  def validate
    @errors = []
    @validation_details = {
      step: nil,
      passed_steps: [],
      failed_steps: [],
      offerer: nil,
      expected_offerer: nil,
      order_hash_computed: nil,
      order_hash_provided: nil,
      recovered_signer: nil,
      signature_valid: nil,
      zone_validation: nil
    }

    # 步骤 1: 验证用户地址与 offerer 一致
    step1_passed = validate_offerer_match
    return { success: false, errors: @errors, details: @validation_details } unless step1_passed

    # 步骤 2: 验证 order_hash
    step2_passed = validate_order_hash
    return { success: false, errors: @errors, details: @validation_details } unless step2_passed

    # 步骤 3: 验证签名
    step3_passed = validate_signature
    return { success: false, errors: @errors, details: @validation_details } unless step3_passed

    # 步骤 4: 验证 Zone 限制
    step4_passed = validate_zone_restrictions
    return { success: false, errors: @errors, details: @validation_details } unless step4_passed

    # 步骤 4.5: 验证 startAmount 必须等于 endAmount
    step45_passed = validate_amount_range_not_allowed
    return { success: false, errors: @errors, details: @validation_details } unless step45_passed

    # 步骤 4.6: Collection 买单仅允许数量 1
    step46_passed = validate_collection_offer_single_amount
    return { success: false, errors: @errors, details: @validation_details } unless step46_passed

    # 步骤 5: 验证余额与授权
    step5_passed = validate_asset_capacity
    return { success: false, errors: @errors, details: @validation_details } unless step5_passed

    @validation_details[:step] = :all_passed
    @validation_details[:passed_steps] = [:offerer_match, :order_hash_match, :signature_valid, :zone_valid, :amount_range_not_allowed, :collection_offer_single_amount, :asset_capacity]

    Rails.logger.info "[OrderValidateService] 订单验证全部通过: user=#{@user.address}"

    { success: true, errors: [], details: @validation_details }
  end

  # 快速验证（仅返回 Boolean）
  #
  # @return [Boolean]
  #
  def valid?
    result = validate
    result[:success]
  end

  private

  # 获取参数的辅助方法（兼容 symbol 和 string key）
  def get_param(params, key)
    params[key] || params[key.to_s] || params[key.to_sym]
  end

  # 步骤 1: 验证用户地址与 offerer 一致
  def validate_offerer_match
    @validation_details[:step] = :offerer_match

    expected_offerer = @user.address.to_s.downcase
    actual_offerer = get_param(@order_params[:parameters], :offerer).to_s.downcase

    @validation_details[:expected_offerer] = expected_offerer
    @validation_details[:offerer] = actual_offerer

    if actual_offerer.blank?
      @errors << "订单参数中缺少 offerer"
      @validation_details[:failed_steps] << :offerer_match
      Rails.logger.warn "[OrderValidateService] offerer 为空"
      return false
    end

    if actual_offerer != expected_offerer
      @errors << "订单 offerer (#{actual_offerer}) 与用户地址 (#{expected_offerer}) 不匹配"
      @validation_details[:failed_steps] << :offerer_match
      Rails.logger.warn "[OrderValidateService] offerer 不匹配: expected=#{expected_offerer}, actual=#{actual_offerer}"
      return false
    end

    @validation_details[:passed_steps] << :offerer_match
    Rails.logger.info "[OrderValidateService] 步骤1通过: offerer 匹配"
    true
  end

  # 步骤 2: 验证 order_hash
  def validate_order_hash
    @validation_details[:step] = :order_hash_match

    provided_hash = @order_params[:order_hash].to_s.downcase
    @validation_details[:order_hash_provided] = provided_hash

    if provided_hash.blank?
      @errors << "订单缺少 order_hash"
      @validation_details[:failed_steps] << :order_hash_match
      Rails.logger.warn "[OrderValidateService] order_hash 为空"
      return false
    end

    # 计算 order hash
    begin
      computed_hash = Seaport::SignatureService.calculate_order_hash(@order_params[:parameters])
      computed_hash_normalized = computed_hash.to_s.downcase
      @validation_details[:order_hash_computed] = computed_hash_normalized

      if computed_hash_normalized != provided_hash
        @errors << "order_hash 不匹配: 计算值=#{computed_hash_normalized}, 传入值=#{provided_hash}"
        @validation_details[:failed_steps] << :order_hash_match
        Rails.logger.warn "[OrderValidateService] order_hash 不匹配: computed=#{computed_hash_normalized}, provided=#{provided_hash}"
        return false
      end
    rescue StandardError => e
      @errors << "计算 order_hash 失败: #{e.message}"
      @validation_details[:failed_steps] << :order_hash_match
      Rails.logger.error "[OrderValidateService] 计算 order_hash 失败: #{e.message}"
      return false
    end

    @validation_details[:passed_steps] << :order_hash_match
    Rails.logger.info "[OrderValidateService] 步骤2通过: order_hash 匹配"
    true
  end

  # 步骤 3: 验证签名
  def validate_signature
    @validation_details[:step] = :signature_valid

    signature = @order_params[:signature].to_s
    order_hash = @order_params[:order_hash]
    offerer = get_param(@order_params[:parameters], :offerer)

    @validation_details[:signature] = signature[0..20] + "..." if signature.length > 20

    if signature.blank?
      @errors << "订单缺少 signature"
      @validation_details[:failed_steps] << :signature_valid
      Rails.logger.warn "[OrderValidateService] signature 为空"
      return false
    end

    # 使用 Seaport::SignatureService 验证签名
    begin
      result = Seaport::SignatureService.validate_signature_with_details(
        offerer: offerer,
        order_hash: order_hash,
        signature: signature
      )

      @validation_details[:signature_valid] = result[:valid]
      @validation_details[:recovered_signer] = result[:details][:recovered_signer]

      unless result[:valid]
        error_msg = result[:details][:message] || "签名验证失败"
        @errors << "签名验证失败: #{error_msg}"
        @validation_details[:failed_steps] << :signature_valid
        Rails.logger.warn "[OrderValidateService] 签名验证失败: #{error_msg}, recovered=#{result[:details][:recovered_signer]}, expected=#{offerer}"
        return false
      end
    rescue StandardError => e
      @errors << "签名验证异常: #{e.message}"
      @validation_details[:failed_steps] << :signature_valid
      Rails.logger.error "[OrderValidateService] 签名验证异常: #{e.message}"
      return false
    end

    @validation_details[:passed_steps] << :signature_valid
    Rails.logger.info "[OrderValidateService] 步骤3通过: 签名有效, signer=#{@validation_details[:recovered_signer]}"
    true
  end

  # 步骤 4: 验证 Zone 限制
  def validate_zone_restrictions
    @validation_details[:step] = :zone_valid

    # 使用 ZoneValidationService 验证
    zone_service = Orders::ZoneValidationService.new
    result = zone_service.validate(@order_params[:parameters], @user.address)

    @validation_details[:zone_validation] = result[:details]

    unless result[:success]
      @errors.concat(result[:errors])
      @validation_details[:failed_steps] << :zone_valid
      Rails.logger.warn "[OrderValidateService] Zone 验证失败: #{result[:errors].join(', ')}"
      return false
    end

    @validation_details[:passed_steps] << :zone_valid
    Rails.logger.info "[OrderValidateService] 步骤4通过: Zone 限制验证通过"
    true
  end

  # 步骤 4.5: 验证 startAmount 必须等于 endAmount（在范围订单功能开放前）
  def validate_amount_range_not_allowed
    @validation_details[:step] = :amount_range_not_allowed

    # 验证 offer 项
    offer_items = get_param(@order_params[:parameters], :offer) || []
    offer_items.each_with_index do |item, index|
      start_amount = item[:startAmount] || item['startAmount']
      end_amount = item[:endAmount] || item['endAmount']

      if start_amount.to_i != end_amount.to_i
        @errors << "offer[#{index}] 的 startAmount (#{start_amount}) 必须等于 endAmount (#{end_amount})"
        @validation_details[:failed_steps] << :amount_range_not_allowed
        Rails.logger.warn "[OrderValidateService] offer[#{index}] 金额范围无效: startAmount=#{start_amount}, endAmount=#{end_amount}"
        return false
      end
    end

    # 验证 consideration 项
    consideration_items = get_param(@order_params[:parameters], :consideration) || []
    consideration_items.each_with_index do |item, index|
      start_amount = item[:startAmount] || item['startAmount']
      end_amount = item[:endAmount] || item['endAmount']

      if start_amount.to_i != end_amount.to_i
        @errors << "consideration[#{index}] 的 startAmount (#{start_amount}) 必须等于 endAmount (#{end_amount})"
        @validation_details[:failed_steps] << :amount_range_not_allowed
        Rails.logger.warn "[OrderValidateService] consideration[#{index}] 金额范围无效: startAmount=#{start_amount}, endAmount=#{end_amount}"
        return false
      end
    end

    @validation_details[:passed_steps] << :amount_range_not_allowed
    Rails.logger.info "[OrderValidateService] 步骤4.5通过: startAmount == endAmount 验证通过"
    true
  end

  # 步骤 5: 验证余额与授权
  def validate_asset_capacity
    @validation_details[:step] = :asset_capacity

    order_type = infer_order_type
    return true if order_type.nil?

    offerer = get_param(@order_params[:parameters], :offerer).to_s.downcase
    seaport_address = Rails.application.config.x.blockchain.seaport_contract_address

    if order_type == 'Offer'
      currency_address = offer_token_address
      required_amount = max_offer_amount

      balance_result = Matching::OverMatch::Detection.send(:get_player_currency_balance, offerer, currency_address)
      if balance_result[:error]
        Rails.logger.warn "[OrderValidateService] ⚠️ 余额查询失败，跳过余额校验: error=#{balance_result[:error]}"
        @validation_details[:passed_steps] << :asset_capacity
        return true
      end
      available_balance = balance_result[:balance]
      required_total = required_amount + existing_order_currency_required(offerer, currency_address)
      allowance_result = Matching::OverMatch::Detection.send(
        :get_player_currency_allowance,
        offerer,
        currency_address,
        seaport_address
      )
      if allowance_result[:error]
        Rails.logger.warn "[OrderValidateService] ⚠️ 授权查询失败，跳过余额校验: error=#{allowance_result[:error]}"
        @validation_details[:passed_steps] << :asset_capacity
        return true
      end
      allowance_amount = allowance_result[:allowance]
      if allowance_amount < required_total
        @errors << "ERC20 授权不足"
        @validation_details[:failed_steps] << :asset_capacity
        Rails.logger.warn "[OrderValidateService] ERC20授权不足: required=#{required_total}, allowance=#{allowance_amount}"
        return false
      end

      if available_balance < required_total
        @errors << "余额不足，无法创建买单"
        @validation_details[:failed_steps] << :asset_capacity
        Rails.logger.warn "[OrderValidateService] 余额不足: required=#{required_total}, available=#{available_balance}"
        return false
      end
    elsif order_type == 'List'
      token_id = offer_token_identifier

      approval_result = Matching::OverMatch::Detection.send(:get_player_token_approval, offerer, seaport_address)
      if approval_result[:error]
        Rails.logger.warn "[OrderValidateService] ⚠️ ERC1155授权查询失败，跳过余额校验: error=#{approval_result[:error]}"
        @validation_details[:passed_steps] << :asset_capacity
        return true
      end
      approved = approval_result[:approved]
      unless approved
        @errors << "ERC1155 授权不足"
        @validation_details[:failed_steps] << :asset_capacity
        Rails.logger.warn "[OrderValidateService] ERC1155授权不足"
        return false
      end

      unless criteria_identifier?(token_id)
        required_amount = max_offer_amount
        balance_result = Matching::OverMatch::Detection.send(:get_player_token_balance, offerer, token_id)
        if balance_result[:error]
          Rails.logger.warn "[OrderValidateService] ⚠️ Token余额查询失败，跳过余额校验: error=#{balance_result[:error]}"
          @validation_details[:passed_steps] << :asset_capacity
          return true
        end
        available_balance = balance_result[:balance]
        required_total = required_amount + existing_order_token_required(offerer, token_id)
        if available_balance < required_total
          @errors << "余额不足，无法创建卖单"
          @validation_details[:failed_steps] << :asset_capacity
          Rails.logger.warn "[OrderValidateService] Token余额不足: required=#{required_total}, available=#{available_balance}"
          return false
        end
      else
        Rails.logger.info "[OrderValidateService] criteria订单跳过Token余额检查"
      end
    end

    @validation_details[:passed_steps] << :asset_capacity
    Rails.logger.info "[OrderValidateService] 步骤5通过: 余额与授权验证通过"
    true
  end

  # 步骤 4.6: Collection 买单仅允许数量 1
  def validate_collection_offer_single_amount
    @validation_details[:step] = :collection_offer_single_amount

    return mark_collection_amount_step_passed unless collection_offer_with_criteria?

    requested_quantity = collection_offer_quantity
    if requested_quantity != 1
      @errors << "Collection 买单仅支持数量 1"
      @validation_details[:failed_steps] << :collection_offer_single_amount
      Rails.logger.warn "[OrderValidateService] Collection买单数量无效: requested=#{requested_quantity}, expected=1"
      return false
    end

    mark_collection_amount_step_passed
  end

  def infer_order_type
    offer_token = offer_token_address
    consideration_token = consideration_token_address

    return 'List' if nft_token?(offer_token)
    return 'Offer' if nft_token?(consideration_token)

    nil
  end

  def offer_token_address
    offer_items = get_param(@order_params[:parameters], :offer) || []
    offer_items.first&.[](:token) || offer_items.first&.[]('token')
  end

  def consideration_token_address
    consideration_items = get_param(@order_params[:parameters], :consideration) || []
    consideration_items.first&.[](:token) || consideration_items.first&.[]('token')
  end

  def offer_token_identifier
    offer_items = get_param(@order_params[:parameters], :offer) || []
    offer_items.first&.[](:identifierOrCriteria) || offer_items.first&.[]('identifierOrCriteria')
  end

  def criteria_identifier?(identifier)
    identifier.is_a?(String) && identifier.start_with?("0x") && identifier.length == 66
  end

  def max_offer_amount
    offer_items = get_param(@order_params[:parameters], :offer) || []
    start_amount = offer_items.sum { |item| (item[:startAmount] || item['startAmount']).to_i }
    end_amount = offer_items.sum { |item| (item[:endAmount] || item['endAmount']).to_i }
    [start_amount, end_amount].max
  end

  def collection_offer_with_criteria?
    return false unless infer_order_type == 'Offer'

    collection_nft_consideration_items.any?
  end

  def collection_offer_quantity
    collection_nft_consideration_items.sum do |item|
      (item[:startAmount] || item['startAmount']).to_i
    end
  end

  def collection_nft_consideration_items
    consideration_items = get_param(@order_params[:parameters], :consideration) || []

    consideration_items.select do |item|
      token = item[:token] || item['token']
      identifier = item[:identifierOrCriteria] || item['identifierOrCriteria']
      nft_token?(token) && criteria_identifier?(identifier)
    end
  end

  def mark_collection_amount_step_passed
    @validation_details[:passed_steps] << :collection_offer_single_amount
    true
  end

  def existing_order_currency_required(offerer, currency_address)
    orders = Trading::Order.where(
      offerer: offerer,
      order_direction: 'Offer',
      offer_token: currency_address,
      onchain_status: %w[pending validated partially_filled],
      offchain_status: %w[active matching]
    )

    orders.sum { |order| Orders::OrderHelper.calculate_unfill_amount_from_order(order).to_i }
  end

  def existing_order_token_required(offerer, token_id)
    return 0 if token_id.blank?

    orders = Trading::Order.where(
      offerer: offerer,
      order_direction: 'List',
      offer_identifier: token_id,
      onchain_status: %w[pending validated partially_filled],
      offchain_status: %w[active matching]
    )

    orders.sum { |order| Orders::OrderHelper.calculate_unfill_amount_from_order(order).to_i }
  end

  def nft_token?(token_address)
    return false if token_address.blank?

    nft_contract = Rails.application.config.x.blockchain.nft_contract_address

    return false if nft_contract.blank?

    token_address.to_s.downcase == nft_contract.to_s.downcase
  end
end
