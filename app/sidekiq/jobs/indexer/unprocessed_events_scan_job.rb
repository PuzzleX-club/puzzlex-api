require 'sidekiq-scheduler'

module Jobs::Indexer
  # 补偿任务：扫描并处理未同步的OrderEvent
  #
  # 场景：
  # 1. OrderEvent已保存但OrderFulfilled事件未创建对应的OrderFill
  # 2. 异步Job失败导致订单状态未更新
  # 3. 系统故障期间的事件遗漏
  #
  # 运行频率：每5分钟
  class UnprocessedEventsScanJob
    include Sidekiq::Job

    # 扫描时间范围：最近24小时
    SCAN_WINDOW = 24.hours

    # 每次处理的最大事件数
    BATCH_SIZE = 50

    def perform(*args)
      Rails.logger.info "[UnprocessedEventsScan] 开始扫描未处理的事件..."

      stats = {
        scanned: 0,
        reprocessed: 0,
        failed: 0
      }

      # 1. 扫描OrderFulfilled事件但没有对应OrderFill的情况
      unprocessed_fulfilled_events = find_unfulfilled_events
      stats[:scanned] += unprocessed_fulfilled_events.size

      unprocessed_fulfilled_events.each do |event|
        begin
          Rails.logger.info "[UnprocessedEventsScan] 重新处理事件 ##{event.id} (#{event.event_name})"

          # 调用EventListener的同步处理方法
          Orders::EventListener.send(:process_event_synchronously, event)

          stats[:reprocessed] += 1
        rescue => e
          Rails.logger.error "[UnprocessedEventsScan] 处理事件 ##{event.id} 失败: #{e.message}"
          stats[:failed] += 1
        end
      end

      # 2. 扫描未synced的事件（Synced字段为false或nil）
      unsynced_events = find_unsynced_events
      stats[:scanned] += unsynced_events.size

      unsynced_events.each do |event|
        begin
          Rails.logger.info "[UnprocessedEventsScan] 同步事件 ##{event.id} (#{event.event_name})"

          # 重新触发状态更新
          Orders::EventApplier.apply_event(event)

          stats[:reprocessed] += 1
        rescue => e
          Rails.logger.error "[UnprocessedEventsScan] 同步事件 ##{event.id} 失败: #{e.message}"
          stats[:failed] += 1
        end
      end

      Rails.logger.info "[UnprocessedEventsScan] 完成: 扫描 #{stats[:scanned]} 个事件, 重新处理 #{stats[:reprocessed]} 个, 失败 #{stats[:failed]} 个"

      stats
    end

    private

    # 查找OrderFulfilled事件但没有对应OrderFill的情况
    def find_unfulfilled_events
      Trading::OrderEvent
        .where(event_name: 'OrderFulfilled')
        .where('created_at > ?', SCAN_WINDOW.ago)
        .where.not(order_hash: nil)
        .limit(BATCH_SIZE)
        .select do |event|
          # 检查是否存在对应的OrderFill
          !Trading::OrderFill.exists?(
            transaction_hash: event.transaction_hash,
            order: Trading::Order.find_by(order_hash: event.order_hash)
          )
        end
    end

    # 查找未synced的事件
    def find_unsynced_events
      Trading::OrderEvent
        .where(synced: [false, nil])
        .where('created_at > ?', SCAN_WINDOW.ago)
        .where(event_name: ['OrderFulfilled', 'OrderValidated', 'OrderCancelled'])
        .limit(BATCH_SIZE)
    end
  end
end
