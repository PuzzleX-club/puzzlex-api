# frozen_string_literal: true

module Client
  module Explorer
    # Explorer API 基类
    # =====================================
    # 公开查询API，无需认证，类似区块链浏览器
    # 提供物品、Instance、玩家、转移记录的查询功能
    #
    # 安全措施：
    # - 限流保护（防止大量请求）
    # - 分页限制（最大100条/页）
    # - 查询超时控制
    #
    class BaseController < ::Client::PublicController
      include Client::RequestLocale
      include Client::IndexerAvailabilityHandling

      # 默认分页配置
      DEFAULT_PAGE_SIZE = 20
      MAX_PAGE_SIZE = 100
      ADVANCE_EXTENSION_FIELDS = %w[
        wealth_value
        drop_scenes
        booth_fees
        destructible
        given_skill_id
        on_chain_delay
        resource_instructions
        token_task_level
        token_task_refresh_type
        user_type
      ].freeze

      # 分页参数解析
      def pagination_params
        page = (params[:page] || 1).to_i
        per_page = (params[:per_page] || DEFAULT_PAGE_SIZE).to_i
        per_page = [per_page, MAX_PAGE_SIZE].min # 限制最大值

        { page: page, per_page: per_page }
      end

      # Keyset分页参数解析（基于cursor）
      def keyset_params
        per_page = (params[:per_page] || DEFAULT_PAGE_SIZE).to_i
        per_page = [per_page, MAX_PAGE_SIZE].min

        {
          cursor: params[:cursor], # 上一页最后一条的ID
          per_page: per_page,
          direction: params[:direction] || 'desc' # 默认倒序
        }
      end

      # 构建分页元数据
      def pagination_meta(collection, page, per_page, total_count = nil)
        # 如果已经提供了total_count，不要重新计算
        unless total_count
          total_count = collection.respond_to?(:total_count) ? collection.total_count : collection.count
        end
        total_pages = (total_count.to_f / per_page).ceil

        {
          current_page: page,
          per_page: per_page,
          total_count: total_count,
          total_pages: total_pages,
          has_more: page < total_pages
        }
      end

      # Keyset分页元数据
      def keyset_meta(collection, per_page)
        has_more = collection.size > per_page
        items = has_more ? collection[0..-2] : collection
        last_item = items.last

        {
          per_page: per_page,
          has_more: has_more,
          next_cursor: last_item&.id
        }
      end

      # 时间范围参数解析（默认最近30天）
      def time_range_params
        end_time = params[:end_time] ? Time.at(params[:end_time].to_i) : Time.current
        start_time = params[:start_time] ? Time.at(params[:start_time].to_i) : end_time - 30.days

        { start_time: start_time, end_time: end_time }
      end

      # 通用错误处理
      rescue_from ActiveRecord::StatementInvalid, with: :handle_query_timeout

      private

      def handle_query_timeout(exception)
        if exception.message.include?('timeout')
          render_error('查询超时，请缩小查询范围', :request_timeout)
        else
          raise exception
        end
      end

      # ===== 物品信息序列化与缓存 =====

      # 单个物品信息（带缓存）
      def fetch_item_info(item_id, locale = request_locale)
        return nil if item_id.blank?

        cache_key = "puzzlex:explorer:item_info:#{catalog_provider.provider_key}:#{item_id}:#{locale}"
        Rails.cache.fetch(cache_key, expires_in: 1.hour) do
          item = catalog_provider.find_item(item_id)
          serialize_item(item, locale) if item
        end
      rescue StandardError => e
        Rails.logger.warn "[Explorer] 获取物品信息失败 item_id=#{item_id}: #{e.message}"
        nil
      end

      # 批量物品信息（带缓存）
      def fetch_items_info(item_ids, locale = request_locale)
        ids = Array(item_ids).map(&:to_i).reject(&:zero?).uniq.sort
        return [] if ids.empty?

        cache_key = "puzzlex:explorer:items_info:#{catalog_provider.provider_key}:#{ids.join(',')}:#{locale}"
        Rails.cache.fetch(cache_key, expires_in: 30.minutes) do
          items_by_id = Array(catalog_provider.find_items(ids)).index_by { |item| item.item_id.to_i }
          ids.filter_map do |id|
            item = items_by_id[id]
            serialize_item(item, locale) if item
          end
        end
      rescue StandardError => e
        Rails.logger.warn "[Explorer] 批量获取物品信息失败 ids=#{ids.inspect}: #{e.message}"
        []
      end

      # 物品序列化：分 base/advance，并包含翻译与便捷字段
      def serialize_item(item, locale = request_locale)
        translations_index = item.translations.index_by(&:locale)

        base = {
          item_id: item.item_id,
          icon: parse_icon_array(item.icon),
          item_type: item.item_type,
          sub_type: item.extra('sub_type'),
          quality: item.extra('quality', []),
          talent_ids: normalize_talent_ids(item.extra('talent_ids', [])),
          use_level: item.extra('use_level')
        }

        advance = {
          can_mint: item.can_mint,
          sellable: item.sellable,
          source_hash: item.source_hash
        }.merge(build_advance_extensions(item)).compact

        {
          base: base,
          advance: advance.presence,
          translations: item.translations.map { |t| { locale: t.locale, name: t.name, description: t.description } },
          name: translations_index[locale.to_s]&.name || translations_index['zh']&.name || translations_index['zh-CN']&.name || "Item##{item.item_id}",
          description: translations_index[locale.to_s]&.description || translations_index['zh']&.description || translations_index['zh-CN']&.description,
          image_url: parse_icon_array(item.icon).first
        }
      end

      # 标准化 talent_ids 为数组格式（处理空对象 {} 的情况）
      def normalize_talent_ids(talent_ids_field)
        return [] if talent_ids_field.blank?

        # 如果是 Hash（PostgreSQL 的 {} 可能解析为空Hash）
        return [] if talent_ids_field.is_a?(Hash) && talent_ids_field.empty?

        # 如果是数组，返回数组
        return talent_ids_field if talent_ids_field.is_a?(Array)

        # 其他情况尝试转为数组
        Array(talent_ids_field).compact
      rescue StandardError => e
        Rails.logger.warn "[Explorer] 标准化talent_ids失败: #{e.message}"
        []
      end

      # 解析 icon 字段为字符串数组
      def parse_icon_array(icon_field)
        return [] if icon_field.blank?

        if icon_field.is_a?(String)
          trimmed = icon_field.strip
          if trimmed.start_with?('{', '[')
            parsed = JSON.parse(trimmed) rescue nil
            if parsed
              if parsed.is_a?(Hash)
                url = parsed['url'] || parsed['image']
                return url ? [url] : []
              end
              return Array(parsed)
            end
          end
          [trimmed]
        elsif icon_field.is_a?(Array)
          icon_field.compact
        else
          Array(icon_field)
        end
      rescue StandardError
        Array(icon_field)
      end

      def build_advance_extensions(item)
        allowed_fields = Array(catalog_provider.capabilities[:extension_fields]).map(&:to_s)

        ADVANCE_EXTENSION_FIELDS.each_with_object({}) do |field, extensions|
          next unless allowed_fields.include?(field)

          value = item.extra(field)
          extensions[field.to_sym] = value unless value.nil?
        end
      end

      # 格式化地址显示
      def format_address(address)
        return nil if address.blank?
        return '0x0000...0000 (Mint/Burn)' if address == '0x0000000000000000000000000000000000000000'

        "#{address[0..5]}...#{address[-4..]}"
      end

      # 判断交易类型
      def transaction_type(from_address, to_address)
        zero_address = '0x0000000000000000000000000000000000000000'

        if from_address == zero_address || from_address.blank?
          'mint'
        elsif to_address == zero_address || to_address.blank?
          'burn'
        else
          'transfer'
        end
      end

      def catalog_provider
        @catalog_provider ||= Metadata::Catalog::ProviderRegistry.current
      end
    end
  end
end
