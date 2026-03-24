# frozen_string_literal: true

# 订单撮合前置验证服务
#
# 在触发撮合前验证订单的有效性：
# 1. 过期时间检查（start_time / end_time）
# 2. 余额检查（货币余额 / NFT 余额）
# 3. 原生代币检查（不支持自动撮合）
# 4. 签名验证
# 5. Zone 限制验证
#
class Matching::State::OrderPreValidator
  # 验证失败原因枚举
  VALIDATION_REASONS = {
    balance_insufficient: 'balance_insufficient',
    token_insufficient: 'token_insufficient',
    expired: 'expired',
    not_yet_valid: 'not_yet_valid',
    signature_invalid: 'signature_invalid',
    zone_restriction_failed: 'zone_restriction_failed',
    native_token_unsupported: 'native_token_unsupported'
  }.freeze

  # 验证失败原因中文描述
  VALIDATION_REASON_DESCRIPTIONS = {
    'balance_insufficient' => '货币余额不足',
    'token_insufficient' => 'NFT 余额不足',
    'expired' => '订单已过期',
    'not_yet_valid' => '订单尚未生效',
    'signature_invalid' => '签名无效',
    'zone_restriction_failed' => '代币不在白名单中',
    'native_token_unsupported' => '不支持原生代币'
  }.freeze

  def initialize
    @logger = Rails.logger
  end

  # 验证单个订单
  #
  # @param order [Trading::Order] 订单对象
  # @return [Hash] { valid: Boolean, reason: Symbol/nil, details: Hash }
  #
  def validate(order)
    @logger.debug "[OrderPreValidator] 开始验证订单: #{order.order_hash[0..12]}..."

    # 1. 检查过期时间
    expiration_result = check_expiration(order)
    unless expiration_result[:valid]
      @logger.debug "[OrderPreValidator] 订单 #{order.order_hash[0..12]}... 过期检查失败: #{expiration_result[:reason]}"
      return expiration_result
    end

    # 2. 检查原生代币
    if order.contains_native_token?
      @logger.debug "[OrderPreValidator] 订单 #{order.order_hash[0..12]}... 包含原生代币"
      return {
        valid: false,
        reason: VALIDATION_REASONS[:native_token_unsupported],
        details: { check: 'native_token' }
      }
    end

    # 3. 检查余额（仅针对 active 状态的订单）
    balance_result = check_balance(order)
    unless balance_result[:valid]
      @logger.debug "[OrderPreValidator] 订单 #{order.order_hash[0..12]}... 余额检查失败: #{balance_result[:reason]}"
      return balance_result
    end

    # 4. 签名验证
    signature_result = check_signature(order)
    unless signature_result[:valid]
      @logger.debug "[OrderPreValidator] 订单 #{order.order_hash[0..12]}... 签名检查失败: #{signature_result[:reason]}"
      return signature_result
    end

    # 5. Zone 限制验证
    zone_result = check_zone_restrictions(order)
    unless zone_result[:valid]
      @logger.debug "[OrderPreValidator] 订单 #{order.order_hash[0..12]}... Zone 检查失败: #{zone_result[:reason]}"
      return zone_result
    end

    @logger.debug "[OrderPreValidator] 订单 #{order.order_hash[0..12]}... 验证通过"
    { valid: true, reason: nil, details: {} }
  rescue => e
    @logger.error "[OrderPreValidator] 订单验证异常: #{order&.order_hash} - #{e.message}"
    {
      valid: false,
      reason: :validation_error,
      details: { error: e.message }
    }
  end

  # 批量验证订单
  #
  # @param orders [Array<Trading::Order>] 订单列表
  # @return [Hash] { valid_orders: Array, invalid_orders: Array }
  #
  def validate_batch(orders)
    valid_orders = []
    invalid_orders = []

    orders.each do |order|
      result = validate(order)
      if result[:valid]
        valid_orders << order
      else
        invalid_orders << { order: order, result: result }
      end
    end

    {
      valid_orders: valid_orders,
      invalid_orders: invalid_orders,
      valid_count: valid_orders.size,
      invalid_count: invalid_orders.size
    }
  end

  private

  # 检查过期时间
  def check_expiration(order)
    now = Time.current.to_i

    # 检查 start_time（订单尚未生效）
    if order.start_time.present? && order.start_time != Rails.application.config.x.blockchain.seaport_max_uint256
      start_ts = parse_timestamp(order.start_time)
      if start_ts && now < start_ts
        return {
          valid: false,
          reason: VALIDATION_REASONS[:not_yet_valid],
          details: { check: 'start_time', now: now, start_time: start_ts }
        }
      end
    end

    # 检查 end_time（订单已过期）
    if order.end_time.present? && order.end_time != Rails.application.config.x.blockchain.seaport_max_uint256
      end_ts = parse_timestamp(order.end_time)
      if end_ts && now > end_ts
        return {
          valid: false,
          reason: VALIDATION_REASONS[:expired],
          details: { check: 'end_time', now: now, end_time: end_ts }
        }
      end
    end

    { valid: true, reason: nil, details: {} }
  end

  # 解析时间戳
  def parse_timestamp(time_str)
    # time_str 可能是 Unix 时间戳（数字字符串）或特殊值
    return nil if time_str.blank?
    return nil if time_str == Rails.application.config.x.blockchain.seaport_max_uint256

    Integer(time_str.to_s) rescue nil
  end

  # 检查余额
  def check_balance(order)
    result = Matching::OverMatch::Detection.check_order_balance_and_approval(order)
    return { valid: true, reason: nil, details: {} } if result[:sufficient]

    case result[:reason]
    when 'erc1155_approval_missing'
      return {
        valid: false,
        reason: VALIDATION_REASONS[:token_insufficient],
        details: { check: 'token', direction: 'List', reason: 'erc1155_approval_missing' }
      }
    when 'erc20_allowance_insufficient'
      return {
        valid: false,
        reason: VALIDATION_REASONS[:balance_insufficient],
        details: { check: 'currency', direction: 'Offer', reason: 'erc20_allowance_insufficient' }
      }
    when 'token_insufficient'
      return {
        valid: false,
        reason: VALIDATION_REASONS[:token_insufficient],
        details: { check: 'token', direction: 'List' }
      }
    when 'currency_insufficient'
      return {
        valid: false,
        reason: VALIDATION_REASONS[:balance_insufficient],
        details: { check: 'currency', direction: 'Offer' }
      }
    end

    { valid: true, reason: nil, details: {} }
  end

  # 签名验证
  def check_signature(order)
    return { valid: true, reason: nil, details: {} } if order.signature.blank?
    return { valid: true, reason: nil, details: {} } if order.order_hash.blank?

    begin
      result = Seaport::SignatureService.validate_signature_with_details(
        offerer: order.offerer,
        order_hash: order.order_hash,
        signature: order.signature
      )

      unless result[:valid]
        return {
          valid: false,
          reason: VALIDATION_REASONS[:signature_invalid],
          details: {
            recovered_signer: result[:details][:recovered_signer],
            expected_signer: order.offerer.downcase,
            message: result[:details][:message]
          }
        }
      end
    rescue => e
      @logger.error "[OrderPreValidator] 签名验证异常: #{e.message}"
      return {
        valid: false,
        reason: VALIDATION_REASONS[:signature_invalid],
        details: { error: e.message }
      }
    end

    { valid: true, reason: nil, details: {} }
  end

  # Zone 限制验证
  def check_zone_restrictions(order)
    begin
      order_params = build_order_params_from_order(order)
      return { valid: true, reason: nil, details: {} } if order_params.nil?

      zone_service = Orders::ZoneValidationService.new
      result = zone_service.validate(order_params, order.offerer)

      unless result[:success]
        return {
          valid: false,
          reason: VALIDATION_REASONS[:zone_restriction_failed],
          details: {
            errors: result[:errors],
            details: result[:details]
          }
        }
      end
    rescue => e
      @logger.error "[OrderPreValidator] Zone 验证异常: #{e.message}"
      return {
        valid: false,
        reason: VALIDATION_REASONS[:zone_restriction_failed],
        details: { error: e.message }
      }
    end

    { valid: true, reason: nil, details: {} }
  end

  # 从订单对象构建 order_params
  def build_order_params_from_order(order)
    return nil if order.parameters.blank?

    begin
      params = JSON.parse(order.parameters) rescue nil
      return nil unless params.is_a?(Hash)

      {
        offer: params['offer'] || params[:offer],
        consideration: params['consideration'] || params[:consideration],
        orderType: params['orderType'] || params[:orderType],
        startTime: params['startTime'] || params[:startTime],
        endTime: params['endTime'] || params[:endTime]
      }
    rescue => e
      @logger.error "[OrderPreValidator] 解析订单参数失败: #{e.message}"
      nil
    end
  end
end
