# frozen_string_literal: true

class Matching::OverMatch::StatusReconciler
  def backup_and_set_over_matched(order, reason, resource_id)
    existing_backup = Trading::OrderStatusBackup.active.find_by(order_hash: order.order_hash)

    unless existing_backup
      Trading::OrderStatusBackup.create_backup!(order, reason, resource_id)
      Rails.logger.info "[OverMatch] 已备份订单 #{order.order_hash} 的状态: #{order.offchain_status}"
    end

    Orders::OrderStatusManager.new(order).set_offchain_status!(
      'over_matched',
      "#{reason}: #{resource_id}"
    )
    Rails.logger.info "[OverMatch] 订单 #{order.order_hash} 已设为超匹配状态"
  end

  def restore_order_from_backup(order)
    backup = Trading::OrderStatusBackup.active.find_by(order_hash: order.order_hash)
    return unless backup

    original_status = backup.original_offchain_status
    Orders::OrderStatusManager.new(order).set_offchain_status!(
      original_status,
      '余额充足，自动恢复'
    )

    backup.restore!
    Rails.logger.info "[OverMatch] 订单 #{order.order_hash} 已从备份恢复，原状态: #{original_status || 'nil'}"
  end

  def build_skipped_balance_result(resource_type, resource_id, orders_count, error)
    {
      resource_type: resource_type,
      resource_id: resource_id.to_s,
      required_amount: nil,
      available_amount: nil,
      is_sufficient: nil,
      orders_count: orders_count,
      over_matched_count: 0,
      restored_count: 0,
      skipped: true,
      reason: 'balance_check_failed',
      error: error
    }
  end
end
