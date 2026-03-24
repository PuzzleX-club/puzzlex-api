# frozen_string_literal: true

module Notifications
  # 订单状态通知服务
  # 在订单状态变化时创建用户消息通知
  class OrderStatusService
    class << self
      DEFAULT_PROJECT = Rails.application.config.x.project.default_key.freeze

      ORDER_FILLED_TYPE = 'order_filled'.freeze
      ORDER_PARTIALLY_FILLED_TYPE = 'order_partially_filled'.freeze

      def notify_order_filled(order, counterparty_address:, filled_amount:, is_maker: false, user_id: nil)
        user_id ||= order.user_id

        action = is_maker ? '卖出' : '买入'
        content = build_filled_content(order, counterparty_address, filled_amount, is_maker)

        data = {
          order_id: order.id,
          order_hash: order.order_hash,
          market_id: order.market_id,
          item_id: order.item_id,
          token_id: order.token_id,
          filled_amount: filled_amount,
          is_maker: is_maker
        }

        message = User::MessageService.create_message(
          Accounts::User.find(user_id),
          ORDER_FILLED_TYPE,
          "订单已成交 #{action}",
          content,
          data,
          DEFAULT_PROJECT,
          priority: :normal
        )

        Rails.logger.info "[Notifications::OrderStatusService] 订单成交通知已创建: user_id=#{user_id}, order_id=#{order.id}, message_id=#{message.id}"
        message
      end

      def notify_partially_filled(order, counterparty_address:, filled_amount:, remaining_amount:, is_maker: false, user_id: nil)
        user_id ||= order.user_id

        action = is_maker ? '卖出' : '买入'
        content = build_partially_filled_content(order, counterparty_address, filled_amount, remaining_amount, is_maker)

        data = {
          order_id: order.id,
          order_hash: order.order_hash,
          market_id: order.market_id,
          item_id: order.item_id,
          token_id: order.token_id,
          filled_amount: filled_amount,
          remaining_amount: remaining_amount,
          is_maker: is_maker
        }

        message = User::MessageService.create_message(
          Accounts::User.find(user_id),
          ORDER_PARTIALLY_FILLED_TYPE,
          "订单部分成交 #{action}",
          content,
          data,
          DEFAULT_PROJECT,
          priority: :normal
        )

        Rails.logger.info "[Notifications::OrderStatusService] 订单部分成交通知已创建: user_id=#{user_id}, order_id=#{order.id}, message_id=#{message.id}"
        message
      end

      def notify_cancelled(order, reason: nil, user_id: nil)
        user_id ||= order.user_id

        content = if reason.present?
                    "您的订单已取消。取消原因：#{reason}"
                  else
                    '您的订单已取消。'
                  end

        data = {
          order_id: order.id,
          order_hash: order.order_hash,
          market_id: order.market_id,
          item_id: order.item_id,
          token_id: order.token_id,
          reason: reason
        }

        message = User::MessageService.create_message(
          Accounts::User.find(user_id),
          'order_cancelled',
          '订单已取消',
          content,
          data,
          DEFAULT_PROJECT,
          priority: :normal
        )

        Rails.logger.info "[Notifications::OrderStatusService] 订单取消通知已创建: user_id=#{user_id}, order_id=#{order.id}, message_id=#{message.id}"
        message
      end

      def notify_system_alert(user, title, content, priority: :important, data: {})
        message = User::MessageService.create_message(
          user,
          'system_alert',
          title,
          content,
          data,
          DEFAULT_PROJECT,
          priority: priority
        )

        Rails.logger.info "[Notifications::OrderStatusService] 系统警告通知已创建: user_id=#{user.id}, message_id=#{message.id}"
        message
      end

      private

      def build_filled_content(order, counterparty_address, filled_amount, is_maker)
        action = is_maker ? '卖出' : '买入'
        short_address = "#{counterparty_address[0..5]}...#{counterparty_address[-4..-1]}"

        "您#{action}的 #{order.item_id} (Token: #{order.token_id}) 已全部成交。\n" \
          "成交数量：#{filled_amount}\n" \
          "对方地址：#{short_address}"
      end

      def build_partially_filled_content(order, counterparty_address, filled_amount, remaining_amount, is_maker)
        action = is_maker ? '卖出' : '买入'
        short_address = "#{counterparty_address[0..5]}...#{counterparty_address[-4..-1]}"

        "您#{action}的 #{order.item_id} (Token: #{order.token_id}) 部分成交。\n" \
          "本次成交：#{filled_amount}\n" \
          "剩余数量：#{remaining_amount}\n" \
          "对方地址：#{short_address}"
      end
    end
  end
end
