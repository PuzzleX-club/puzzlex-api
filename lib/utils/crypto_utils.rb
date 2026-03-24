# frozen_string_literal: true

require 'bigdecimal'
require 'bigdecimal/util'

# 通用加密货币工具类
# 处理单位转换、精度格式化等与区块链资产相关的通用操作
module CryptoUtils
  class << self
    # 将 Wei 转换为 ETH
    # @param wei_amount [Numeric] wei数量
    # @param precision [Integer] 小数位数
    # @return [Float] ETH数量
    def wei_to_eth(wei_amount, precision: 8)
      return 0.0 if wei_amount.nil? || wei_amount.zero?

      (BigDecimal(wei_amount.to_s) / (10**18)).round(precision).to_f
    end

    # 将 ETH 转换为 Wei
    # @param eth_amount [Numeric] ETH数量
    # @return [Integer] wei数量
    def eth_to_wei(eth_amount)
      return 0 if eth_amount.nil? || eth_amount.zero?

      (eth_amount.to_f * (10**18)).to_i
    end

    # 格式化大数字为可读字符串（带千分位分隔符）
    # @param amount [Numeric] 数字
    # @param precision [Integer] 小数位数
    # @return [String] 格式化后的字符串
    def format_amount(amount, precision = 4)
      return '0' if amount.nil? || amount.zero?

      format('%.<precision>f', amount).gsub(/(\d)(?=(\d{3})+(?!\d))/, '\1,')
    end

    # 安全地将字符串转换为整数
    # @param value [String, Integer, BigDecimal] 值
    # @return [Integer] 整数
    def safe_to_i(value)
      return value.to_i if value.is_a?(Integer)

      BigDecimal(value.to_s).to_i
    end

    # 安全地将字符串转换为浮点数
    # @param value [String, Integer, BigDecimal] 值
    # @param precision [Integer] 精度
    # @return [Float] 浮点数
    def safe_to_f(value, precision = nil)
      result = BigDecimal(value.to_s).to_f
      precision ? result.round(precision) : result
    end
  end
end
