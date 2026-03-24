require 'set'

module Client
  module NFT
    class ItemsController < ::Client::PublicController  # 去鉴权，允许公开读取
      def info
        item = CatalogData::Item.includes(:translations).find_by(item_id: params[:id])
        return render_success({}, "物品不存在") if item.blank?

        has_collection = Merkle::TreeRoot.active.where(item_id: item.item_id).exists?

        render_success({
          item_id: item.item_id,
          name_cn: item.name('zh'),
          name_en: item.name('en'),
          description_cn: item.description('zh'),
          description_en: item.description('en'),
          image_url: parse_icon_url(item.icon),
          classification: item.item_type,
          specialization: item.extra('sub_type'),
          has_collection: has_collection
        }, "获取物品数据成功")
      end

      # 批量物品信息查询
      def batch_info
        # 约定: JSON body { ids: ["1","2","3"] }
        ids = Array(params[:ids]).map(&:to_s).uniq
        return render_success([], "空列表") if ids.empty?

        items = CatalogData::Item.includes(:translations).where(item_id: ids)
        item_ids = items.pluck(:item_id).map(&:to_s)
        merkle_item_ids = Merkle::TreeRoot.active.where(item_id: item_ids).distinct.pluck(:item_id).map(&:to_s)
        merkle_item_ids_set = merkle_item_ids.to_set

        items_data = items.map do |item|
          {
            item_id: item.item_id,
            name_cn: item.name('zh'),
            name_en: item.name('en'),
            description_cn: item.description('zh'),
            description_en: item.description('en'),
            image_url: parse_icon_url(item.icon),
            classification: item.item_type,
            specialization: item.extra('sub_type'),
            has_collection: merkle_item_ids_set.include?(item.item_id.to_s)
          }
        end

        render_success(items_data, "获取物品数据成功")
      end

      private

      # 解析icon字段的JSON数组，返回第一个URL
      def parse_icon_url(icon_field)
        return nil if icon_field.blank?

        begin
          parsed = JSON.parse(icon_field)
          if parsed.is_a?(Array) && parsed.any?
            return parsed.first
          end
        rescue JSON::ParserError => e
          Rails.logger.warn "[ItemsController] Failed to parse icon JSON: #{icon_field}, error: #{e.message}"
        end

        # 如果解析失败，尝试直接返回（可能已经是URL字符串）
        icon_field
      end
    end
  end
end
