# frozen_string_literal: true

# app/controllers/admin/items_controller.rb
#
# Admin 物品管理控制器
# 提供链上物品的查询功能
#
# API 端点:
#   GET /api/admin/items - 获取物品列表
#
# 权限: Admin

module Admin
  class ItemsController < ::Admin::ApplicationController
    # GET /api/admin/items
    # 获取物品列表（支持分页和过滤）
    #
    # 参数:
    #   page - 页码（默认 1）
    #   per_page - 每页数量（默认 20，最大 100）
    #   item_type - 按物品类型过滤
    #   sellable - 按是否可交易过滤 (true/false)
    #   search - 搜索关键词（匹配名称）
    #
    # 响应:
    #   {
    #     code: 0,
    #     message: "Success",
    #     data: {
    #       items: [...],
    #       meta: { current_page, total_pages, total_count, per_page }
    #     }
    #   }
    def index
      items = CatalogData::Item.all

      # 过滤条件
      items = items.by_type(params[:item_type]) if params[:item_type].present?
      items = items.sellable if params[:sellable] == 'true'

      # 搜索（通过翻译表）
      if params[:search].present?
        search_term = "%#{params[:search]}%"
        items = items.joins(:translations)
                     .where("#{CatalogData::ItemTranslation.table_name}.name ILIKE ?", search_term)
                     .distinct
      end

      # 排序
      items = items.order(item_id: :asc)

      # 分页
      page_params = pagination_params
      items = items.page(page_params[:page]).limit(page_params[:per_page])

      # 预加载市场信息
      item_ids = items.pluck(:item_id)
      markets_by_item = Trading::Market.where(item_id: item_ids)
                                       .group_by(&:item_id)
      merkle_item_ids = Merkle::TreeRoot.active
                                              .where(item_id: item_ids)
                                              .distinct
                                              .pluck(:item_id)
                                              .map(&:to_s)
                                              .to_set

      render_success({
        items: items.map { |item| serialize_item(item, markets_by_item, merkle_item_ids) },
        meta: pagination_meta(items),
        # 添加可用代币列表
        available_tokens: get_available_tokens
      })
    end

    private

    def serialize_item(item, markets_by_item = {}, merkle_item_ids = Set.new)
      markets = markets_by_item[item.item_id] || []

      {
        item_id: item.item_id,
        name_cn: item.name('zh'),
        name_en: item.name('en'),
        description_cn: item.description('zh'),
        description_en: item.description('en'),
        image_url: parse_icon_url(item.icon),
        item_type: item.item_type,
        sub_type: item.extra('sub_type'),
        quality: item.extra('quality', []),
        can_mint: item.can_mint,
        sellable: item.sellable,
        has_collection: merkle_item_ids.include?(item.item_id.to_s),
        # 市场信息
        markets: markets.map do |market|
          {
            market_id: market.market_id,
            name: market.name,
            quote_currency: market.quote_currency,
            payment_type: market.payment_type
          }
        end,
        is_listed: markets.any?,
        # 是否可以创建新市场（每个物品最多两种支付类型：eth和erc20）
        can_create_market: markets.size < 2
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

    # 获取可用的代币列表（ETH + ERC20）
    def get_available_tokens
      tokens = []

      # 添加 ETH
      tokens << {
        symbol: 'ETH',
        address: '0x0000000000000000000000000000000000000000000',
        name: 'Ethereum',
        payment_type: 'eth'
      }

      # 添加 ERC20 代币（从配置中获取）
      erc20_config = Rails.application.config.x.price_tokens&.dig('01')
      if erc20_config
        tokens << {
          symbol: erc20_config[:symbol],
          address: erc20_config[:address],
          name: erc20_config[:name] || 'ERC20 Token',
          payment_type: 'erc20'
        }
      end

      tokens
    end
  end
end
