# app/services/orders/order_status_updater.rb
module Orders
  class OrderStatusUpdater
    def self.update_order_status(order_hash)
      Rails.logger.info "[OrderStatusUpdater] 开始更新订单状态：order_hash=#{order_hash}"
      
      order = Trading::Order.find_by(order_hash: order_hash)
      unless order
        Rails.logger.warn "[OrderStatusUpdater] 订单未找到：order_hash=#{order_hash}"
        return { message: '订单未找到，但程序继续运行' }
      end

      Rails.logger.info "[OrderStatusUpdater] 当前数据库状态: onchain_status=#{order.onchain_status}, is_validated=#{order.is_validated}, is_cancelled=#{order.is_cancelled}"
      
      contract_service = Seaport::ContractService.new
      order_status_data = contract_service.get_order_status(order.order_hash)
      
      Rails.logger.info "[OrderStatusUpdater] 链上查询结果: #{order_status_data.inspect}"

      if order_status_data[:error].nil?
        is_validated = order_status_data[:is_validated]
        is_cancelled = order_status_data[:is_cancelled]
        total_filled = order_status_data[:total_filled].to_i
        total_size   = order_status_data[:total_size].to_i

        Orders::OrderStatusManager.new(order).update_onchain_status!(
          is_validated: is_validated,
          is_cancelled: is_cancelled,
          total_filled: total_filled,
          total_size: total_size,
          reason: "contract_status_sync"
        )

        Rails.logger.info "[OrderStatusUpdater] 订单状态已更新：order_hash=#{order_hash}, is_validated=#{is_validated}, is_cancelled=#{is_cancelled}"
        { message: '订单状态已更新' }
      else
        Rails.logger.error "无法获取订单状态：order_hash=#{order_hash}, error=#{order_status_data[:error]}"
        { error: order_status_data[:error] }
      end
    end
  end
end
