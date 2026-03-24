# frozen_string_literal: true

# app/controllers/admin/stats_controller.rb
#
# Admin 统计数据控制器
# 提供平台统计数据概览
#
# API 端点:
#   GET /api/admin/stats - 获取平台统计数据
#
# 权限: Admin

module Admin
  class StatsController < ::Admin::ApplicationController
    # GET /api/admin/stats
    # 获取平台统计数据
    #
    # 响应:
    #   {
    #     code: 0,
    #     message: "Success",
    #     data: {
    #       overview: { ... },
    #       orders: { ... },
    #       markets: { ... },
    #       users: { ... }
    #     }
    #   }
    def index
      render_success({
        overview: overview_stats,
        orders: order_stats,
        markets: market_stats,
        users: user_stats
      })
    end

    private

    def overview_stats
      {
        total_users: Accounts::User.count,
        total_markets: Trading::Market.count,
        total_orders: Trading::Order.count,
        total_fills: Trading::OrderFill.count
      }
    end

    def order_stats
      orders = Trading::Order.all

      # 按链上状态统计 (onchain_status: pending, validated, partially_filled, filled, cancelled)
      on_chain_status_counts = orders.group(:onchain_status).count

      # 按链下状态统计 (offchain_status: active, over_matched, expired, paused, matching, validation_failed, closed)
      offchain_status_counts = orders.group(:offchain_status).count

      # 按方向统计 (List/Offer)
      direction_counts = orders.group(:order_direction).count

      # 今日订单
      today_start = Time.zone.now.beginning_of_day
      today_orders = orders.where('created_at >= ?', today_start)

      # 已完全成交的订单 (total_filled >= total_size)
      filled_orders = orders.where('total_filled >= total_size AND total_size > 0')
      today_filled = today_orders.where('total_filled >= total_size AND total_size > 0')
      recent_filled = filled_orders.where('updated_at >= ?', 24.hours.ago)

      {
        by_on_chain_status: on_chain_status_counts,   # 链上状态统计
        by_offchain_status: offchain_status_counts, # 链下状态统计
        by_direction: direction_counts,
        today: {
          created: today_orders.count,
          filled: today_filled.count
        },
        recent_24h: {
          created: orders.where('created_at >= ?', 24.hours.ago).count,
          filled: recent_filled.count
        }
      }
    end

    def market_stats
      markets = Trading::Market.all

      # 按支付类型统计
      payment_type_counts = markets.group(:payment_type).count

      # 活跃市场（有活跃订单的市场）
      # 定义活跃订单：已验证、未取消、链下状态为active或matching
      active_market_ids = Trading::Order
                            .where(is_validated: true, is_cancelled: false)
                            .where(offchain_status: %w[active matching])
                            .distinct
                            .pluck(:market_id)

      {
        total: markets.count,
        by_payment_type: payment_type_counts,
        active_count: active_market_ids.count
      }
    end

    def user_stats
      users = Accounts::User.all

      # 按权限级别统计
      admin_level_counts = users.group(:admin_level).count

      # 活跃用户（有订单的用户）
      active_trader_count = Trading::Order.distinct.count(:offerer)

      {
        total: users.count,
        by_admin_level: admin_level_counts,
        active_traders: active_trader_count,
        today_registered: users.where('created_at >= ?', Time.zone.now.beginning_of_day).count
      }
    end
  end
end
