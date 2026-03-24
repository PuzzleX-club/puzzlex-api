# frozen_string_literal: true

# 物品属性筛选服务
#
# 提供可复用的物品属性筛选逻辑，用于通过 catalog items 表筛选订单、实例等记录。
#
# @example 基础用法
#   query = Trading::Order.all
#   filtered_query = Catalog::ItemFilterService.apply_filters(
#     query,
#     use_levels: [1, 2],
#     item_types: [10, 20],
#     talent_ids: [5]
#   )
#
# @example 指定关联类型
#   # 仅筛选 offer 物品
#   query = Catalog::ItemFilterService.apply_filters(query, use_levels: [1], join_type: :offer)
#
#   # 仅筛选 consideration 物品
#   query = Catalog::ItemFilterService.apply_filters(query, use_levels: [1], join_type: :consideration)
#
module Catalog
  class ItemFilterService
  # 应用物品属性筛选
  #
  # @param query [ActiveRecord::Relation] 基础查询（如 Trading::Order.all）
  # @param use_levels [Array<Integer>, nil] 使用等级筛选
  # @param talent_ids [Array<Integer>, nil] 天赋筛选
  # @param item_types [Array<Integer>, nil] 物品类型筛选
  # @param join_type [Symbol] :offer（仅offer）, :consideration（仅consideration）, :both（默认，offer或consideration）
  # @return [ActiveRecord::Relation] 筛选后的查询
    def self.apply_filters(query, use_levels: nil, talent_ids: nil, item_types: nil, join_type: :both)
      # 如果没有任何筛选条件，直接返回原查询
      return query unless use_levels.present? || talent_ids.present? || item_types.present?

      # 关联 catalog items 表
      query = join_items_table(query, join_type)

      # 构建筛选条件
      conditions = build_filter_conditions(use_levels, talent_ids, item_types, join_type)

      # 应用筛选条件
      query = query.where(conditions.join(' AND ')) if conditions.any?

      query
    end

    # 关联 catalog items 表
    #
    # @param query [ActiveRecord::Relation] 基础查询
    # @param join_type [Symbol] 关联类型
    # @return [ActiveRecord::Relation] 关联后的查询
    def self.join_items_table(query, join_type)
      items_table = CatalogData::Item.table_name
      orders_table = ::Trading::Order.table_name

      case join_type
      when :offer
        query.joins(
          "LEFT JOIN #{items_table} AS offer_items ON #{orders_table}.offer_item_id = offer_items.item_id::bigint"
        )
      when :consideration
        query.joins(
          "LEFT JOIN #{items_table} AS consideration_items ON #{orders_table}.consideration_item_id = consideration_items.item_id::bigint"
        )
      when :both
        query.joins(
          "LEFT JOIN #{items_table} AS offer_items ON #{orders_table}.offer_item_id = offer_items.item_id::bigint " \
          "LEFT JOIN #{items_table} AS consideration_items ON #{orders_table}.consideration_item_id = consideration_items.item_id::bigint"
        )
      else
        raise ArgumentError, "Invalid join_type: #{join_type}. Must be :offer, :consideration, or :both"
      end
    end
    private_class_method :join_items_table

    # 构建筛选条件
    #
    # @param use_levels [Array<Integer>, nil] 使用等级
    # @param talent_ids [Array<Integer>, nil] 天赋
    # @param item_types [Array<Integer>, nil] 物品类型
    # @param join_type [Symbol] 关联类型
    # @return [Array<String>] SQL 条件数组
    def self.build_filter_conditions(use_levels, talent_ids, item_types, join_type)
      conditions = []

      # 等级筛选
      if use_levels.present?
        conditions << build_jsonb_scalar_condition('use_level', use_levels, join_type)
      end

      # 类型筛选
      if item_types.present?
        conditions << build_condition('item_type', item_types, join_type)
      end

      # 天赋筛选（数组字段，使用 && 操作符）
      if talent_ids.present?
        conditions << build_jsonb_array_overlap_condition('talent_ids', talent_ids, join_type)
      end

      conditions.compact
    end
    private_class_method :build_filter_conditions

    # 构建单个字段的筛选条件
    #
    # @param field [String] 字段名
    # @param values [Array] 筛选值
    # @param join_type [Symbol] 关联类型
    # @return [String] SQL 条件
    def self.build_condition(field, values, join_type)
      case join_type
      when :offer
        "offer_items.#{field} IN (#{values.join(',')})"
      when :consideration
        "consideration_items.#{field} IN (#{values.join(',')})"
      when :both
        "(offer_items.#{field} IN (#{values.join(',')}) OR consideration_items.#{field} IN (#{values.join(',')}))"
      end
    end
    private_class_method :build_condition

    def self.build_jsonb_scalar_condition(field, values, join_type)
      jsonb_any_match_condition(field, values, join_type)
    end
    private_class_method :build_jsonb_scalar_condition

    def self.build_jsonb_array_overlap_condition(field, values, join_type)
      jsonb_any_match_condition(field, Array(values).map { |value| [value] }, join_type)
    end
    private_class_method :build_jsonb_array_overlap_condition

    def self.jsonb_any_match_condition(field, values, join_type)
      values = Array(values).compact.uniq
      return nil if values.empty?

      if join_type == :offer
        return jsonb_match_group('offer_items', field, values)
      elsif join_type == :consideration
        return jsonb_match_group('consideration_items', field, values)
      end

      offer_group = jsonb_match_group('offer_items', field, values)
      consideration_group = jsonb_match_group('consideration_items', field, values)
      "(#{offer_group} OR #{consideration_group})"
    end
    private_class_method :jsonb_any_match_condition

    def self.jsonb_match_group(table_alias, field, values)
      quoted_conditions = values.map do |value|
        payload = { field => value }.to_json
        "#{table_alias}.extra_data @> #{ActiveRecord::Base.connection.quote(payload)}::jsonb"
      end

      "(#{quoted_conditions.join(' OR ')})"
    end
    private_class_method :jsonb_match_group

    # 构建数组字段的筛选条件
    #
    # @param field [String] 字段名
    # @param values [Array] 筛选值
    # @param join_type [Symbol] 关联类型
    # @return [String] SQL 条件
    def self.build_array_condition(field, values, join_type)
      case join_type
      when :offer
        jsonb_match_group('offer_items', field, Array(values).map { |value| [value] })
      when :consideration
        jsonb_match_group('consideration_items', field, Array(values).map { |value| [value] })
      when :both
        "(#{jsonb_match_group('offer_items', field, Array(values).map { |value| [value] })} OR " \
          "#{jsonb_match_group('consideration_items', field, Array(values).map { |value| [value] })})"
      end
    end
    private_class_method :build_array_condition
  end
end
