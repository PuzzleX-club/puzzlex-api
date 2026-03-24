# frozen_string_literal: true

require 'bigdecimal'
require 'bigdecimal/util'
require 'utils/crypto_utils'

module MarketData
  # 统一的价格计算服务
  # 处理所有与价格相关的计算，包括从price_distribution计算价格、单位转换等
  class PriceCalculator
    class << self
      # 从 OrderFill 计算价格（Wei）
      # @param fill [Trading::OrderFill] 订单成交记录
      # @return [Integer] 价格（Wei）
      def calculate_price_from_fill(fill)
        return 0 unless fill&.price_distribution

        # 解析JSON格式的price_distribution
        price_distribution = case fill.price_distribution
                            when String
                              JSON.parse(fill.price_distribution)
                            when Array
                              fill.price_distribution
                            else
                              return 0
                            end

        calculate_price(price_distribution, fill.filled_amount)
      rescue JSON::ParserError
        0
      end

      # 从 price_distribution 和 filled_amount 计算价格
      # @param price_distribution [Array] 价格分布数组
      # @param filled_amount [Numeric] 成交数量（备用，优先使用price_distribution中的值）
      # @return [Integer] 价格（Wei）
      def calculate_price(price_distribution, filled_amount = nil)
        return 0 unless valid_price_distribution?(price_distribution)

        distribution = price_distribution.first
        total_amount = BigDecimal(distribution["total_amount"].to_s)

        # 优先使用 price_distribution 中的 filled_amount；缺失时退回到传入的 filled_amount
        distribution_filled_amount = distribution["filled_amount"]
        effective_filled_amount =
          if distribution_filled_amount.present?
            BigDecimal(distribution_filled_amount.to_s)
          elsif filled_amount.present?
            BigDecimal(filled_amount.to_s)
          else
            BigDecimal('0')
          end

        return 0 if effective_filled_amount.zero?

        price = total_amount / effective_filled_amount
        price.to_i
      end
      
      # 将 wei 转换为 ETH
      # @param wei_amount [Numeric] wei数量
      # @param precision [Integer] 精度
      # @return [Float] ETH数量
      def wei_to_eth(wei_amount, precision: 8)
        CryptoUtils.wei_to_eth(wei_amount, precision: precision)
      end

      # 将 ETH 转换为 wei
      # @param eth_amount [Numeric] ETH数量
      # @return [Integer] wei数量
      def eth_to_wei(eth_amount)
        CryptoUtils.eth_to_wei(eth_amount)
      end
      
      # 从 OrderFill 计算价格并转换为 ETH
      # @param fill [Trading::OrderFill] 订单成交记录
      # @param precision [Integer] 精度
      # @return [Float] 价格（ETH）
      def calculate_price_in_eth(fill, precision: 8)
        price_in_wei = calculate_price_from_fill(fill)
        wei_to_eth(price_in_wei, precision: precision)
      end
      
      # 批量计算价格（用于性能优化）
      # @param fills [Array<Trading::OrderFill>] 订单成交记录数组
      # @return [Hash] { fill_id => price_in_wei }
      def batch_calculate_prices(fills)
        fills.each_with_object({}) do |fill, result|
          result[fill.id] = calculate_price_from_fill(fill)
        end
      end
      
      private
      
      # 验证 price_distribution 格式
      def valid_price_distribution?(price_distribution)
        return false unless price_distribution.is_a?(Array)
        return false if price_distribution.empty?
        
        distribution = price_distribution.first
        return false unless distribution.is_a?(Hash)
        
        # 放宽验证条件，与Legacy逻辑保持一致
        # Legacy逻辑会尝试解析任何存在的price_distribution
        true
      end
    end
  end
end
