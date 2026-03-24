# frozen_string_literal: true

module Indexer
  # NFT Transfer事件监听器
  # 监听ERC1155的TransferSingle和TransferBatch事件
  class EventListener
    EVENT_TYPE = 'item_indexer'

    class << self
      # 主入口：监听事件
      def listen_to_events
        latest_block = latest_block_number
        if latest_block.nil?
          Rails.logger.error "[Indexer] 无法获取最新区块号，跳过本次执行"
          return
        end

        from_block = resolve_from_block
        if from_block > latest_block
          Rails.logger.debug "[Indexer] 起始区块 #{from_block} 高于最新区块 #{latest_block}，跳过"
          return
        end

        begin
          processed_count = process_transfer_events(from_block: from_block, to_block: latest_block)
          update_checkpoint(latest_block)

          if processed_count.zero?
            Rails.logger.debug "[Indexer] 本轮扫描完成：无新事件"
          else
            Rails.logger.info "[Indexer] 本轮处理完成：共 #{processed_count} 个事件"
          end
        rescue StandardError => e
          Rails.logger.error "[Indexer] 处理失败: #{e.class} - #{e.message}"
          record_retry_range(from_block, latest_block, e)
        end
      rescue StandardError => e
        Rails.logger.error "[Indexer] 监听器错误: #{e.message}"
        Rails.logger.error e.backtrace.first(3).join("\n")
      end

      private

      def process_transfer_events(from_block:, to_block:)
        Rails.logger.debug "[Indexer] 处理区块范围: #{from_block}-#{to_block}"

        processor = TransferProcessor.new
        total_count = 0

        # 获取TransferSingle事件
        single_logs = fetch_events('TransferSingle', from_block, to_block)
        Rails.logger.info "[Indexer] 发现 #{single_logs.size} 个 TransferSingle 事件" if single_logs.any?

        single_logs.each_with_index do |log, index|
          processor.process_transfer_single(log)
          total_count += 1

          # 定期释放连接
          ActiveRecord::Base.connection_pool.release_connection if ((index + 1) % 5).zero?
        end

        # 获取TransferBatch事件
        batch_logs = fetch_events('TransferBatch', from_block, to_block)
        Rails.logger.info "[Indexer] 发现 #{batch_logs.size} 个 TransferBatch 事件" if batch_logs.any?

        batch_logs.each_with_index do |log, index|
          processor.process_transfer_batch(log)
          total_count += (log[:ids]&.length || 0)

          ActiveRecord::Base.connection_pool.release_connection if ((index + 1) % 5).zero?
        end

        total_count
      ensure
        ActiveRecord::Base.connection_pool.release_connection
      end

      def fetch_events(event_name, from_block, to_block)
        service = nft_contract_service
        all_logs = []
        current_from = from_block

        while current_from <= to_block
          current_to = [current_from + block_batch_size - 1, to_block].min

          Rails.logger.debug "[Indexer] 查询 #{event_name}: #{current_from}-#{current_to}"

          logs = service.get_event_logs(
            event_name: event_name,
            from_block: current_from,
            to_block: current_to,
            contract_address: contract_address
          )

          all_logs.concat(Array(logs))
          current_from = current_to + 1
        end

        all_logs
      rescue StandardError => e
        Rails.logger.error "[Indexer] 获取#{event_name}事件失败: #{e.message}"
        raise
      end

      def latest_block_number
        nft_contract_service.latest_block_number
      end

      def resolve_from_block
        baseline = start_block
        value = Onchain::EventListenerStatus.last_block(event_type: EVENT_TYPE)

        if value.nil? || value == 'earliest'
          update_checkpoint(baseline)
          return baseline
        end

        numeric_value = value.to_i
        if numeric_value < baseline
          update_checkpoint(baseline)
          baseline
        else
          numeric_value
        end
      end

      def update_checkpoint(block_number)
        Onchain::EventListenerStatus.update_status(EVENT_TYPE, block_number, event_type: EVENT_TYPE)
      end

      def record_retry_range(from_block, to_block, error)
        range = Onchain::EventRetryRange.find_or_initialize_by(
          event_type: EVENT_TYPE,
          from_block: from_block,
          to_block: to_block
        )

        range.attempts = range.attempts.to_i + 1
        range.last_error = "#{error.class}: #{error.message}"
        range.next_retry_at = [range.next_retry_at, Time.current + 5.minutes].compact.max
        range.save!
      rescue StandardError => e
        Rails.logger.error "[Indexer] 写入重试区间失败: #{e.message}"
      end

      # 配置访问器
      def config
        Rails.application.config.x.indexer
      end

      def contract_address
        config.contract_address
      end

      def start_block
        config.start_block
      end

      def block_batch_size
        config.block_batch_size
      end

      def nft_contract_service
        @nft_contract_service ||= NFTContractService.new
      end
    end
  end
end
