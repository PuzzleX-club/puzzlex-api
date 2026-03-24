# frozen_string_literal: true
# 统一管理订单链上/链下状态变更

module Orders
  class OrderStatusManager
    ONCHAIN_STATUSES = %w[pending validated partially_filled filled cancelled].freeze
    OFFCHAIN_STATUSES = %w[active over_matched expired paused matching validation_failed closed match_failed].freeze

    OFFCHAIN_TRANSITIONS = {
      nil => %w[active],
      'active' => %w[matching over_matched expired paused validation_failed],
      'matching' => %w[active paused closed],
      'paused' => %w[active expired over_matched closed match_failed],
      'over_matched' => %w[active],
      'validation_failed' => %w[active],
      'expired' => [],
      'closed' => [],
      'match_failed' => []
    }.freeze

    def initialize(order, logger: Rails.logger)
      @order = order
      @logger = logger
    end

    def update_onchain_status!(is_validated:, is_cancelled:, total_filled:, total_size:, reason: nil, metadata: {})
      @order.with_lock do
        old_total_filled = @order.total_filled.to_i
        old_is_cancelled = @order.is_cancelled

        @order.update!(
          is_validated: is_validated,
          is_cancelled: is_cancelled,
          total_filled: total_filled,
          total_size: total_size
        )

        new_status = calculate_onchain_status
        old_status = @order.onchain_status

        if new_status != old_status
          @order.update!(onchain_status: new_status)
          log_status_change!(:onchain_status, old_status, new_status, reason, metadata)

          # 触发用户通知
          trigger_notification_on_status_change(old_status, new_status, old_total_filled, metadata)
        end

        sync_offchain_after_onchain_change!(new_status)
      end
    end

    def set_offchain_status!(status, reason = nil, metadata = {})
      status = status.to_s
      validate_offchain_transition!(status)

      @order.with_lock do
        old_status = @order.offchain_status

        @order.update!(
          offchain_status: status,
          offchain_status_updated_at: Time.current,
          offchain_status_reason: reason,
          offchain_status_metadata: metadata
        )

        log_status_change!(:offchain_status, old_status, status, reason, metadata)
      end
    end

    private

    def calculate_onchain_status
      return 'cancelled' if @order.is_cancelled
      return 'validated' if @order.is_validated && @order.total_filled.to_i.zero?

      if @order.is_validated && @order.total_filled.to_i.positive? && @order.total_filled.to_i < @order.total_size.to_i
        return 'partially_filled'
      end

      return 'filled' if @order.total_size.to_i.positive? && @order.total_filled.to_i >= @order.total_size.to_i

      'pending'
    end

    def sync_offchain_after_onchain_change!(new_onchain_status)
      target_status = determine_offchain_status_after_onchain_change(new_onchain_status)
      return if target_status.nil? || target_status == @order.offchain_status

      old_status = @order.offchain_status

      @order.update!(
        offchain_status: target_status,
        offchain_status_updated_at: Time.current,
        offchain_status_reason: "onchain_sync: #{new_onchain_status}"
      )

      log_status_change!(:offchain_status, old_status, target_status, "onchain_sync: #{new_onchain_status}")
    end

    def determine_offchain_status_after_onchain_change(new_onchain_status)
      return 'closed' if %w[filled cancelled].include?(new_onchain_status)

      return 'paused' if @order.offchain_status == 'paused'

      'active'
    end

    # 触发状态变更通知
    def trigger_notification_on_status_change(old_status, new_status, old_total_filled, metadata = {})
      # 优先使用 user_id，缺失时回退到 offerer 地址
      user_id = @order.respond_to?(:user_id) ? @order.user_id : nil
      user = if user_id.present?
               Accounts::User.find_by(id: user_id)
             elsif @order.offerer.present?
               Rails.logger.info "[OrderStatusManager] ⚠️ order_id=#{@order.id} 缺少 user_id 字段或值，降级使用 offerer: #{@order.offerer}"
               Accounts::User.find_by(address: @order.offerer.downcase)
             end
      return unless user

      counterparty = metadata[:counterparty_address] || 'unknown'
      is_maker = @order.order_direction == 'List'

      case new_status
      when 'filled'
        # 订单完全成交
        filled_amount = @order.total_filled.to_s
        Notifications::OrderStatusService.notify_order_filled(
          @order,
          counterparty_address: counterparty,
          filled_amount: filled_amount,
          is_maker: is_maker,
          user_id: user.id
        )
      when 'partially_filled'
        # 订单部分成交
        new_filled = @order.total_filled.to_i
        filled_delta = new_filled - old_total_filled
        remaining = @order.total_size.to_i - new_filled

        Notifications::OrderStatusService.notify_partially_filled(
          @order,
          counterparty_address: counterparty,
          filled_amount: filled_delta.to_s,
          remaining_amount: remaining.to_s,
          is_maker: is_maker,
          user_id: user.id
        )
      when 'cancelled'
        # 订单取消
        Notifications::OrderStatusService.notify_cancelled(
          @order,
          reason: metadata[:cancel_reason],
          user_id: user.id
        )
      end
    rescue => e
      @logger.error "[OrderStatusManager] 发送用户通知失败: #{e.message}"
      # 通知失败不影响订单状态更新
    end

    def validate_offchain_transition!(to_status)
      unless OFFCHAIN_STATUSES.include?(to_status)
        raise ArgumentError, "未知链下状态: #{to_status}"
      end

      from_status = @order.offchain_status
      return if from_status == to_status
      allowed = OFFCHAIN_TRANSITIONS.fetch(from_status, [])

      return if allowed.include?(to_status)

      raise ArgumentError, "非法链下状态转换: #{from_status} -> #{to_status}"
    end

    def log_status_change!(status_type, from_status, to_status, reason, metadata = {})
      Trading::OrderStatusLog.log!(
        order: @order,
        status_type: status_type,
        from_status: from_status,
        to_status: to_status,
        reason: reason,
        metadata: metadata
      )
    end
  end
end
