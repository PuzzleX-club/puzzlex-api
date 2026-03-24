# frozen_string_literal: true

module Client
  module Explorer
    class ItemsController < BaseController
      # GET /api/explorer/items
      # 获取所有物品列表（分页+筛选）
      def index
        items = ItemIndexer::Item.all

        # 应用筛选条件
        items = apply_filters(items)

        # 排序：按last_updated倒序
        items = items.order(last_updated: :desc)

        # 分页
        page_params = pagination_params
        # 如果有 keyword 搜索，count 需要 distinct（因为同一物品可能匹配多语言版本）
        total_count = params[:keyword].present? ? items.count("DISTINCT #{ItemIndexer::Item.table_name}.id") : items.count
        items = items.offset((page_params[:page] - 1) * page_params[:per_page])
                     .limit(page_params[:per_page])

        # 组装响应数据
        items_data = items.map { |item| format_item(item) }

        response = {
          items: items_data,
          meta: {
            current_page: page_params[:page],
            per_page: page_params[:per_page],
            total_count: total_count,
            total_pages: (total_count.to_f / page_params[:per_page]).ceil,
            has_more: page_params[:page] < (total_count.to_f / page_params[:per_page]).ceil
          }
        }

        # 如果请求包含 facets 参数，同时返回筛选选项
        if params[:include_facets] == 'true'
          response[:facets] = get_facets_data
        end

        render_success(response)
      end

      # GET /api/explorer/items/facets
      # 返回所有可用于筛选的选项
      def facets
        facets_data = get_facets_data
        render_success(facets_data)
      end

      # GET /api/explorer/items/:id/info
      def info
        locale = request_locale
        item_info = fetch_item_info(params[:id], locale)

        if item_info
          set_cache_headers
          render_success(item_info)
        else
          render_error("物品不存在: #{params[:id]}", :not_found)
        end
      end

      # GET /api/explorer/items/batch_info?ids=1,2,3
      def batch_info
        locale = request_locale
        ids = params[:ids].to_s.split(',').map(&:strip).reject(&:blank?)
        return render_error('参数 ids 不能为空', :bad_request) if ids.empty?

        items = fetch_items_info(ids, locale)
        set_cache_headers
        render_success(items)
      end

      # GET /api/explorer/items/:id
      # 获取单个物品详情
      def show
        query_result = Metadata::Catalog::ItemQueryService.call(
          params[:id], locale: request_locale
        )

        if query_result.nil?
          render_error("物品不存在: #{params[:id]}", :not_found)
          return
        end

        render_success(
          ::Catalog::ItemDetailDTO.from_query_result(query_result).as_json
        )
      end

      # GET /api/explorer/items/:id/instances
      # 获取物品关联的Instance列表
      def instances
        item = ItemIndexer::Item.find_by(id: params[:id])

        if item.nil?
          render_error("物品不存在: #{params[:id]}", :not_found)
          return
        end

        instances = item.instances.includes(:metadata).order(last_updated: :desc)

        # 分页
        page_params = pagination_params
        total_count = instances.count
        instances = instances.offset((page_params[:page] - 1) * page_params[:per_page])
                             .limit(page_params[:per_page])

        instances_data = instances.map { |inst| format_instance(inst) }

        render_success({
          item_id: item.id,
          instances: instances_data,
          meta: {
            current_page: page_params[:page],
            per_page: page_params[:per_page],
            total_count: total_count,
            total_pages: (total_count.to_f / page_params[:per_page]).ceil,
            has_more: page_params[:page] < (total_count.to_f / page_params[:per_page]).ceil
          }
        })
      end

      # GET /api/explorer/items/:id/holders
      # 获取物品持有者分布
      def holders
        item = ItemIndexer::Item.find_by(id: params[:id])

        if item.nil?
          render_error("物品不存在: #{params[:id]}", :not_found)
          return
        end

        # 查询该物品所有Instance的持有者，按总持有量聚合
        instances_table = ItemIndexer::Instance.table_name
        balances_table = ItemIndexer::InstanceBalance.table_name
        holders = ItemIndexer::InstanceBalance
                   .joins("INNER JOIN #{instances_table} ON #{instances_table}.id = #{balances_table}.instance")
                   .where("#{instances_table}.item = ?", item.id)
                   .where("#{balances_table}.balance > 0")
                   .select(
                     "#{balances_table}.player",
                     "SUM(#{balances_table}.balance) as total_balance",
                     "COUNT(DISTINCT #{balances_table}.instance) as instance_count",
                     "MAX(#{balances_table}.timestamp) as last_active"
                   )
                   .group(:player)
                   .order("total_balance DESC")

        # 分页
        page_params = pagination_params
        total_count = holders.length
        holders_page = holders.offset((page_params[:page] - 1) * page_params[:per_page])
                              .limit(page_params[:per_page])

        holders_data = holders_page.map do |holder|
          {
            address: holder.player,
            address_short: format_address(holder.player),
            total_balance: holder.total_balance.to_s,
            instance_count: holder.instance_count,
            last_active: holder.last_active
          }
        end

        render_success({
          item_id: item.id,
          holders: holders_data,
          meta: {
            current_page: page_params[:page],
            per_page: page_params[:per_page],
            total_count: total_count,
            total_pages: (total_count.to_f / page_params[:per_page]).ceil,
            has_more: page_params[:page] < (total_count.to_f / page_params[:per_page]).ceil
          }
        })
      end

      private

      # 应用筛选条件
      def apply_filters(query)
        items_table = CatalogData::Item.table_name
        translations_table = CatalogData::ItemTranslation.table_name
        indexer_items_table = ItemIndexer::Item.table_name

        needs_items_join = params[:use_levels].present? || params[:talent_ids].present? || params[:item_types].present?

        # 名称搜索需要 JOIN 翻译表
        needs_translation_join = params[:keyword].present?

        if needs_items_join
          # 转换类型：indexer items.id 是字符串，需要转换为整数
          query = query.joins("INNER JOIN #{items_table} ON #{items_table}.item_id = CAST(#{indexer_items_table}.id AS integer)")
        end

        # 名称搜索 - JOIN 翻译表
        if needs_translation_join
          # 如果还没有 JOIN items 表，需要先 JOIN（翻译表关联到 item_id）
          unless needs_items_join
            query = query.joins("INNER JOIN #{items_table} ON #{items_table}.item_id = CAST(#{indexer_items_table}.id AS integer)")
          end
          query = query.joins("INNER JOIN #{translations_table} ON #{translations_table}.item_id = #{items_table}.item_id")
        end

        # 名称���糊搜索（匹配所有语言版本）
        if params[:keyword].present?
          keyword = "%#{ActiveRecord::Base.sanitize_sql_like(params[:keyword])}%"
          query = query.where("#{translations_table}.name ILIKE ?", keyword)
        end

        # 使用等级筛选（支持多选）
        if params[:use_levels].present?
          use_levels = params[:use_levels].split(',').map(&:to_i)
          query = query.where(jsonb_any_match_condition(items_table, 'use_level', use_levels))
        end

        # 物品类型筛选（多选）
        if params[:item_types].present?
          item_types = params[:item_types].split(',').map(&:to_i)
          query = query.where("#{items_table}.item_type IN (?)", item_types)
        end

        # 天赋ID筛选（多选）
        if params[:talent_ids].present?
          talent_ids = params[:talent_ids].split(',').map(&:to_i)
          query = query.where(jsonb_array_overlap_condition(items_table, 'talent_ids', talent_ids))
        end

        # 有翻译表 JOIN 时需要 distinct 避免重复（同一物品多语言版本）
        if needs_translation_join
          query = query.distinct
        end

        query
      end

      # 获取 facets 数据（带缓存）
      def get_facets_data
        # facets 缓存键版本化，包含 item_types
        cache_key = "explorer:items:facets:v2"
        Rails.cache.fetch(cache_key, expires_in: 1.hour) do
          {
            use_levels: collect_all_use_levels,
            item_types: collect_all_item_types,
            talent_ids: collect_all_talent_ids
          }
        end
      end

      # 收集所有 use_level 选项（仅索引器中存在的物品）
      def collect_all_use_levels
        CatalogData::Item
          .joins("INNER JOIN #{ItemIndexer::Item.table_name} ON CAST(#{ItemIndexer::Item.table_name}.id AS integer) = #{CatalogData::Item.table_name}.item_id")
          .reorder(nil)
          .where("#{CatalogData::Item.table_name}.extra_data ? 'use_level'")
          .pluck(Arel.sql("DISTINCT (#{CatalogData::Item.table_name}.extra_data->>'use_level')"))
          .filter_map { |value| value&.to_i }
          .uniq
          .sort
      end

      # 收集所有 item_type 选项（仅索引器中存在的物品）
      def collect_all_item_types
        CatalogData::Item
          .joins("INNER JOIN #{ItemIndexer::Item.table_name} ON CAST(#{ItemIndexer::Item.table_name}.id AS integer) = #{CatalogData::Item.table_name}.item_id")
          .reorder(nil)
          .where.not(item_type: nil)
          .pluck(:item_type)
          .compact
          .uniq
          .sort
      end

      # 收集所有 talent_ids 选项（仅索引器中存在的物品）
      def collect_all_talent_ids
        talent_ids = Set.new

        CatalogData::Item
          .joins("INNER JOIN #{ItemIndexer::Item.table_name} ON CAST(#{ItemIndexer::Item.table_name}.id AS integer) = #{CatalogData::Item.table_name}.item_id")
          .reorder(nil)
          .find_each do |item|
            ids = normalize_talent_ids(item.extra('talent_ids', []))
            talent_ids.merge(ids)
          end

        talent_ids.to_a.compact.sort
      end

      def jsonb_any_match_condition(table_name, key, values)
        values = Array(values).compact.uniq
        return '1=0' if values.empty?

        conditions = values.map do |value|
          payload = { key => value }.to_json
          "#{table_name}.extra_data @> #{ActiveRecord::Base.connection.quote(payload)}::jsonb"
        end

        "(#{conditions.join(' OR ')})"
      end

      def jsonb_array_overlap_condition(table_name, key, values)
        values = Array(values).compact.uniq
        return '1=0' if values.empty?

        conditions = values.map do |value|
          payload = { key => [value] }.to_json
          "#{table_name}.extra_data @> #{ActiveRecord::Base.connection.quote(payload)}::jsonb"
        end

        "(#{conditions.join(' OR ')})"
      end

      def format_item(item)
        {
          id: item.id,
          total_supply: item.total_supply.to_s,
          minted_amount: item.minted_amount.to_s,
          burned_amount: item.burned_amount.to_s,
          last_updated: item.last_updated,
          item_info: fetch_item_info(item.id)
        }
      end

      def format_instance(instance)
        metadata = instance.metadata
        {
          id: instance.id,
          item_id: instance.item,
          quality: instance.quality,
          quality_hex: instance.quality,
          total_supply: instance.total_supply.to_s,
          minted_amount: instance.minted_amount.to_s,
          burned_amount: instance.burned_amount.to_s,
          last_updated: instance.last_updated,
          metadata_status: instance.metadata_status,
          metadata: metadata ? {
            name: metadata.name,
            description: metadata.description,
            image: metadata.image
          } : nil
        }
      end

      def set_cache_headers
        response.headers['Cache-Control'] = 'public, max-age=1800'
      end

    end
  end
end
