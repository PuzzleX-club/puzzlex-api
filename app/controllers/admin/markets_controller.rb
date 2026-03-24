# frozen_string_literal: true

# app/controllers/admin/markets_controller.rb
#
# Admin 市场管理控制器
# 提供市场的 CRUD 操作（上架/下架物品）
#
# API 端点:
#   GET    /api/admin/markets     - 获取市场列表
#   POST   /api/admin/markets     - 上架物品（创建市场）
#   DELETE /api/admin/markets/:id - 下架市场
#
# 权限: Admin

module Admin
  class MarketsController < ::Admin::ApplicationController
    # GET /api/admin/markets
    # 获取市场列表（支持分页和过滤）
    #
    # 参数:
    #   page - 页码（默认 1）
    #   per_page - 每页数量（默认 20，最大 100）
    #   payment_type - 按支付类型过滤 (eth/erc20)
    #   item_id - 按物品ID过滤
    #
    # 响应:
    #   {
    #     code: 0,
    #     message: "Success",
    #     data: {
    #       markets: [...],
    #       meta: { current_page, total_pages, total_count, per_page }
    #     }
    #   }
    def index
      markets = Trading::Market.all

      # 过滤条件
      markets = markets.where(payment_type: params[:payment_type]) if params[:payment_type].present?
      markets = markets.where(item_id: params[:item_id]) if params[:item_id].present?

      # 排序
      markets = markets.order(created_at: :desc)

      # 分页
      page_params = pagination_params
      markets = markets.page(page_params[:page]).limit(page_params[:per_page])

      # 预加载物品信息
      item_ids = markets.pluck(:item_id)
      items_by_id = CatalogData::Item.where(item_id: item_ids).index_by(&:item_id)

      render_success({
        markets: markets.map { |market| serialize_market(market, items_by_id) },
        meta: pagination_meta(markets)
      })
    end

    # POST /api/admin/markets
    # 上架物品（创建市场）
    #
    # 参数:
    #   item_id - 物品ID（必需）
    #   payment_type - 支付类型 (eth/erc20，默认 eth)
    #   price_address - 价格代币地址（ERC20模式必需）
    #   quote_currency - 报价货币符号（可选，默认根据payment_type自动设置）
    #
    # 响应:
    #   {
    #     code: 0,
    #     message: "Market created successfully",
    #     data: { market: {...} }
    #   }
    def create
      item_id = params[:item_id]&.to_i
      payment_type = params[:payment_type] || 'eth'

      # 验证物品存在
      item = CatalogData::Item.find_by(item_id: item_id)
      unless item
        return render_error("Item not found: #{item_id}", status: :not_found, code: 404)
      end

      # 验证物品可交易 — 要求 provider 声明 marketplace capability 且 item.sellable 为 true
      provider = Metadata::Catalog::ProviderRegistry.current
      unless provider.capabilities[:marketplace]
        return render_error("Catalog provider does not support marketplace", status: :unprocessable_entity, code: 422)
      end
      unless item.sellable
        return render_error("Item is not sellable: #{item_id}", status: :unprocessable_entity, code: 422)
      end

      # 检查是否已存在相同的市场
      existing_market = Trading::Market.find_by(item_id: item_id, payment_type: payment_type)
      if existing_market
        return render_error("Market already exists for this item and payment type", status: :conflict, code: 409)
      end

      # 构建市场参数
      market_params = build_market_params(item, payment_type)

      market = Trading::Market.new(market_params)

      if market.save
        render_success({
          market: serialize_market(market, { item_id => item })
        }, 'Market created successfully')
      else
        render_error(market.errors.full_messages.join(', '), status: :unprocessable_entity, code: 422)
      end
    end

    # DELETE /api/admin/markets/:id
    # 下架市场
    #
    # 注意: 这里的 :id 是 market_id（主键）
    #
    # 响应:
    #   {
    #     code: 0,
    #     message: "Market deleted successfully",
    #     data: {}
    #   }
    def destroy
      market = Trading::Market.find_by(market_id: params[:id])

      unless market
        return render_error("Market not found: #{params[:id]}", status: :not_found, code: 404)
      end

      # 检查是否有未完成的订单
      active_orders_count = Trading::Order.where(market_id: market.market_id)
                                          .where(status: %w[active validated pending])
                                          .count
      if active_orders_count > 0
        return render_error(
          "Cannot delete market with #{active_orders_count} active orders",
          status: :conflict,
          code: 409
        )
      end

      if market.destroy
        render_success({}, message: 'Market deleted successfully')
      else
        render_error(market.errors.full_messages.join(', '), status: :unprocessable_entity, code: 422)
      end
    end

    private

    def build_market_params(item, payment_type)
      # 根据支付类型获取代币信息
      price_token = get_price_token(payment_type)

      # 生成 market_id: {item_id 4位}{payment_type_code 2位}
      payment_type_code = payment_type == 'eth' ? '00' : '01'
      market_id = "#{item.item_id.to_s.rjust(4, '0')}#{payment_type_code}".to_i

      {
        market_id: market_id,
        item_id: item.item_id,
        name: "#{item.name('en')}/#{price_token[:symbol]}",
        base_currency: item.name('en'),
        quote_currency: price_token[:symbol],
        price_address: price_token[:address],
        payment_type: payment_type
      }
    end

    def get_price_token(payment_type)
      # 从配置中获取代币信息
      token_code = payment_type == 'eth' ? '00' : '01'
      token_config = Rails.application.config.x.price_tokens[token_code]

      if token_config
        {
          symbol: token_config[:symbol],
          address: token_config[:address]
        }
      else
        # 默认值
        if payment_type == 'eth'
          { symbol: 'ETH', address: '0x0000000000000000000000000000000000000000' }
        else
          {
            symbol: 'TT',
            address: Rails.application.config.x.blockchain.erc20_contract_address || '0x0000000000000000000000000000000000000001'
          }
        end
      end
    end

    def serialize_market(market, items_by_id = {})
      item = items_by_id[market.item_id]

      {
        market_id: market.market_id,
        item_id: market.item_id,
        name: market.name,
        base_currency: market.base_currency,
        quote_currency: market.quote_currency,
        price_address: market.price_address,
        payment_type: market.payment_type,
        created_at: market.created_at.iso8601,
        # 物品信息
        item: item ? {
          name_cn: item.name('zh'),
          name_en: item.name('en'),
          image_url: parse_icon_url(item.icon)
        } : nil
      }
    end

    def parse_icon_url(icon_field)
      return nil if icon_field.blank?

      begin
        parsed = JSON.parse(icon_field)
        return parsed.first if parsed.is_a?(Array) && parsed.any?
      rescue JSON::ParserError
        # 忽略解析错误
      end

      icon_field
    end
  end
end
