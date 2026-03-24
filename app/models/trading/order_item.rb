# frozen_string_literal: true

# DEPRECATED - OrderItem 机制暂未在前端使用
#
# 此模型设计用于存储订单中的 item 详情，支持动态数量和价格分配的线性插值。
# 目前插值功能（amount_at_progress, price_distribution_at_progress）未被撮合引擎使用，
# 保留此代码以备未来需要动态定价/数量功能时使用。
#
# 相关 PR/Issue: [待添加]
#
# @deprecated 目前 API 未暴露此数据，如需使用请先评估必要性
module Trading
  class OrderItem < ApplicationRecord

    belongs_to :order, class_name: 'Trading::Order'

    validates :role, presence: true, inclusion: { in: %w[offer consideration] }
    validates :token_address, presence: true
    validates :start_amount, numericality: { greater_than_or_equal_to: 0 }
    validates :end_amount, numericality: { greater_than_or_equal_to: 0 }

    # 假设 start_price_distribution 和 end_price_distribution 是数组结构，如：
    # [
    #   {
    #     "token_address": "0xabc123...",
    #     "item_type": 3,
    #     "token_id": "12345",
    #     "recipients": [
    #       { "address": "0xSellerAddress", "amount": "1.0" },
    #       { "address": "0xRoyaltyAddress", "amount": "0.05" }
    #     ]
    #   },
    #   ... (可能有多个代币)
    # ]

    def price_distribution_at_progress(progress)
      linearly_interpolate_distribution(start_price_distribution, end_price_distribution, progress)
    end

    def amount_at_progress(progress)
      start_amount + (end_amount - start_amount) * progress
    end

    private

    # 对价格分布进行线性插值：
    # start_dist与end_dist为数组，每个元素是一个代币价格分布条目
    # 根据 (token_address, item_type, token_id) 匹配 start 和 end 的条目
    # 对每个匹配条目的 recipients 按 address 匹配，并对 amount 线性插值
    def linearly_interpolate_distribution(start_dist, end_dist, progress)
      result = []

      start_map = build_distribution_map(start_dist)
      end_map   = build_distribution_map(end_dist)

      # 遍历 start_map 中的代币条目
      start_map.each do |key, start_entry|
        end_entry = end_map[key]
        next unless end_entry # 无匹配的end则略过该token条目

        # 对 recipients 进行地址匹配插值
        interpolated_entry = {
          "token_address" => start_entry["token_address"],
          "item_type" => start_entry["item_type"],
          "token_id" => start_entry["token_id"],
          "recipients" => []
        }

        start_recipients_map = recipients_by_address(start_entry["recipients"])
        end_recipients_map   = recipients_by_address(end_entry["recipients"])

        start_recipients_map.each do |address, start_rec|
          end_rec = end_recipients_map[address]
          # 如果 end 中没有此地址，则可认为 end_amt = start_amt 或直接跳过
          if end_rec
            start_amt = start_rec["amount"].to_f
            end_amt = end_rec["amount"].to_f
            current_amt = start_amt + (end_amt - start_amt) * progress
            interpolated_entry["recipients"] << { "address" => address, "amount" => current_amt.to_s }
          else
            # 若没有匹配的recipient，可选择将end视为0或跳过
            # 此处简单跳过没有end对应的recipient
            # 如果想要视为0的话:
            # current_amt = start_rec["amount"].to_f * (1 - progress)
            # interpolated_entry["recipients"] << { "address" => address, "amount" => current_amt.to_s }
          end
        end

        result << interpolated_entry
      end

      result
    end

    # 将分布数组转换成map，key为 [token_address, item_type, token_id]
    def build_distribution_map(dist_array)
      map = {}
      dist_array.each do |entry|
        key = [entry["token_address"], entry["item_type"], entry["token_id"]]
        map[key] = entry
      end
      map
    end

    # 将 recipients 数组转换为以 address 为 key 的 map
    def recipients_by_address(recipients_arr)
      (recipients_arr || []).each_with_object({}) do |r, h|
        h[r["address"]] = r
      end
    end
  end
end
