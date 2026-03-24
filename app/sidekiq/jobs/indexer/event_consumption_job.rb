# frozen_string_literal: true

module Jobs
  module Indexer
    class EventConsumptionJob
      include Sidekiq::Worker

      sidekiq_options queue: :default

      def perform(log_consumption_id)
        lc = Onchain::LogConsumption.find_by(id: log_consumption_id)
        return unless lc
        return unless lc.status == "pending"

        raw = lc.raw_log
        handler_key = lc.handler_key

        case handler_key
        when "order_events"
          process_order_event(lc, raw)
        when "item_indexer"
          process_nft_event(lc, raw)
        else
          raise "Unknown handler_key #{handler_key}"
        end

        lc.update!(status: "success", consumed_at: Time.current)
        Onchain::EventListenerStatus.update_status("handler:#{handler_key}", raw.block_number, event_type: "handler:#{handler_key}")
      rescue => e
        # 如果 lc 为 nil（数据库异常等），直接抛出异常
        unless lc
          Rails.logger.error "[EventConsumptionJob] ❌ lc 为 nil，无法处理: #{e.class}: #{e.message}"
          raise e
        end

        attempts = lc.attempts.to_i + 1
        max_attempts = 10
        retrying = attempts < max_attempts

        # 计算递增等待时间: 1, 2, 4, 8, 16, 32, 60, 60, 60, 60 秒
        wait_time = [2 ** (attempts - 1), 60].min

        # 记录错误信息
        lc.update!(
          status: retrying ? "pending" : "failed",
          attempts: attempts,
          last_error: "#{e.class}: #{e.message}\n#{e.backtrace&.first(3)&.join("\n")}",
          next_retry_at: retrying ? Time.current + wait_time.seconds : nil
        )

        if retrying
          Rails.logger.warn "[EventConsumptionJob] ⚠️ 处理失败，同步重试 (#{attempts}/#{max_attempts})，等待#{wait_time}秒: lc_id=#{lc.id} error=#{e.class}"
          sleep(wait_time)
          perform(lc.id)
        else
          Rails.logger.error "[EventConsumptionJob] ❌ 处理失败，已达重试上限(#{max_attempts}次): lc_id=#{lc.id} error=#{e.message}"
          raise e
        end
      end

      private

      def process_order_event(lc, raw)
        contract_service = Seaport::ContractService.new
        decoded = contract_service.decode_raw_log(raw_log_to_rpc_shape(raw), event_name: raw.event_name)

        # 根据事件名称查找对应的 model
        event_config = Orders::EventListener::EVENTS_TO_WATCH.find { |e| e[:name] == raw.event_name }
        model = event_config ? event_config[:model] : nil

        event_payload = decoded.merge(
          event_name: raw.event_name,
          block_hash: raw.block_hash,
          transaction_index: raw.transaction_index,
          log_index: decoded[:log_index],
          block_number: decoded[:block_number],
          block_timestamp: decoded[:block_timestamp],
          model: model
        )

        Orders::EventListener.process_event(event_payload)
      end

      def process_nft_event(lc, raw)
        nft_service = Indexer::NFTContractService.new
        event_name = raw.event_name || raw.topic0
        decoded = nft_service.decode_raw_log(raw_log_to_rpc_shape(raw), event_name: event_name)
        ts = raw.block_timestamp || nft_service.send(:fetch_block_timestamp, "0x" + raw.block_number.to_i.to_s(16))

        case event_name
        when "TransferSingle"
          event_payload = decoded.merge(
            transaction_hash: raw.transaction_hash,
            log_index: raw.log_index,
            block_number: raw.block_number,
            block_hash: raw.block_hash,
            timestamp: ts
          ).symbolize_keys
          Indexer::TransferProcessor.new.process_transfer_single(event_payload)
        when "TransferBatch"
          event_payload = decoded.merge(
            transaction_hash: raw.transaction_hash,
            log_index: raw.log_index,
            block_number: raw.block_number,
            block_hash: raw.block_hash,
            timestamp: ts
          ).symbolize_keys
          Indexer::TransferProcessor.new.process_transfer_batch(event_payload)
        else
          raise "Unsupported nft event #{event_name}"
        end
      end

      def raw_log_to_rpc_shape(raw)
        {
          "address" => raw.address,
          "topics" => raw.topics,
          "data" => raw.data,
          "blockNumber" => "0x" + raw.block_number.to_i.to_s(16),
          "transactionHash" => raw.transaction_hash,
          "logIndex" => "0x" + raw.log_index.to_i.to_s(16)
        }
      end
    end
  end
end
