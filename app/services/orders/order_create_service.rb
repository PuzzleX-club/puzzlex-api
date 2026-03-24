# frozen_string_literal: true

module Orders
  class OrderCreateService

    attr_reader :user, :order_params, :chain_id, :errors

    def initialize(user, order_params, chain_id = nil)
      @user = user
      @order_params = order_params
      @chain_id = chain_id
      @errors = []
      @order = nil
    end

    def call
      create_order
      return { success: false, errors: @errors, order: nil } if @errors.any?

      { success: true, order: @order, errors: [] }
    rescue StandardError => e
      Rails.logger.error "[OrderCreateService] 创建订单失败: #{e.message}"
      Rails.logger.error e.backtrace.join("\n")
      @errors << e.message
      { success: false, errors: @errors, order: nil }
    end

    def order_hash
      @order&.order_hash
    end

    def order_status
      @order&.offchain_status
    end

    private

    def create_order
      @order = Trading::Order.new(extract_order_params)

      # 从 parameters 中提取相关信息并赋值给订单字段
      extract_order_data(@order, @order_params[:parameters])

      if @order.save
        Orders::OrderStatusManager.new(@order).set_offchain_status!('active', 'order_created')
        Rails.logger.info "[OrderCreateService] 订单创建成功: #{@order.order_hash}"
      else
        @errors = @order.errors.full_messages
        Rails.logger.error "[OrderCreateService] 订单保存失败: #{@errors.join(', ')}"
      end
    end

    def extract_order_params
      {
        order_hash: @order_params[:order_hash],
        signature: @order_params[:signature],
        parameters: @order_params[:parameters] || {}
      }
    end

    # 提取参数并设置到 Order 对象中
    # 复用于客户端交易控制器的 extract_order_data
    def extract_order_data(order, parameters)
      return unless parameters.present?

      # 提取 offerer、startTime、endTime、counter
      # offer切换为小写
      order.offerer = parameters[:offerer].to_s.downcase
      order.start_time = parameters[:startTime]
      order.end_time = parameters[:endTime]
      order.counter = parameters[:counter]
      order.offer_item_id = 0
      order.consideration_item_id = 0
      order.market_id = "0"

      # 提取并汇总 offer 部分
      if parameters[:offer].present?
        offer_data = parameters[:offer].first
        order.offer_token = offer_data[:token]
        order.offer_identifier = offer_data[:identifierOrCriteria]

        order.offer_start_amount = parameters[:offer].sum { |offer| offer[:startAmount].to_i }
        order.offer_end_amount = parameters[:offer].sum { |offer| offer[:endAmount].to_i }

        # 判断是否为 NFT（通过 token 地址）
        if nft_token?(offer_data[:token])
          order.order_direction = "List"
          identifier_or_criteria = offer_data[:identifierOrCriteria]
          order.offer_item_id = extract_item_id(identifier_or_criteria)
        end
      end

      # 提取并汇总 consideration 部分
      if parameters[:consideration].present?
        consideration_data = parameters[:consideration].first
        order.consideration_token = consideration_data[:token]
        order.consideration_identifier = consideration_data[:identifierOrCriteria]
        order.consideration_start_amount = parameters[:consideration].sum { |consideration| consideration[:startAmount].to_i }
        order.consideration_end_amount = parameters[:consideration].sum { |consideration| consideration[:endAmount].to_i }

        # 判断是否为 NFT（通过 token 地址）
        if nft_token?(consideration_data[:token])
          order.order_direction = "Offer"
          identifier_or_criteria = consideration_data[:identifierOrCriteria]
          order.consideration_item_id = extract_item_id(identifier_or_criteria)
        end
      end

      # 计算单价和 market_id
      calculate_market_info(order)
    end

    # 判断 token 地址是否为 NFT 合约
    def nft_token?(token_address)
      return false if token_address.blank?

      nft_contract = Rails.application.config.x.blockchain.nft_contract_address

      return false if nft_contract.blank?

      token_address.downcase == nft_contract.downcase
    end

    # 提取 item_id
    # 优先从 Merkle 树根节点查询，否则从 token_id 解析
    def extract_item_id(identifier_or_criteria)
      return 0 if identifier_or_criteria.blank?

      # 如果是 criteria 模式（以 0x 开头）
      if identifier_or_criteria.is_a?(String) && identifier_or_criteria.start_with?("0x")
        # 查询 MerkleTreeNode 模型中 is_root 为 true 且 node_hash 匹配的记录
        root_node = Merkle::TreeNode.find_by(
          node_hash: identifier_or_criteria,
          is_root: true
        )
        return root_node.item_id if root_node
      end

      # 否则从 token_id 解析
      ::Blockchain::TokenIdParser.new.item_id_int(identifier_or_criteria) || 0
    rescue => e
      Rails.logger.warn "[OrderCreateService] 提取 item_id 失败: #{e.message}"
      0
    end

    # 计算市场信息（单价、market_id）
    def calculate_market_info(order)
      return unless order.order_direction.present?

      if order.order_direction == "Offer"
        # Offer：offer 是价格，consideration 是 NFT
        order.start_price = order.offer_start_amount.to_f / order.consideration_start_amount.to_f
        order.end_price = order.offer_end_amount.to_f / order.consideration_end_amount.to_f

        # 调用 MarketIdParser
        parser = MarketData::MarketIdParser.new(
          item_id: order.consideration_item_id,
          price_address: order.offer_token
        )
        order.market_id = parser.market_id.to_s

      elsif order.order_direction == "List"
        # List：offer 是 NFT，consideration 是价格
        order.start_price = order.consideration_start_amount.to_f / order.offer_start_amount.to_f
        order.end_price = order.consideration_end_amount.to_f / order.offer_end_amount.to_f

        # 调用 MarketIdParser
        parser = MarketData::MarketIdParser.new(
          item_id: order.offer_item_id,
          price_address: order.consideration_token
        )
        order.market_id = parser.market_id.to_s
      end
    rescue => e
      Rails.logger.warn "[OrderCreateService] 计算市场信息失败: #{e.message}"
    end
  end
end
