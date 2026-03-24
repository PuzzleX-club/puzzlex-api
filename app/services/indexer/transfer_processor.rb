# frozen_string_literal: true

module Indexer
  # Transfer事件处理器
  # 完全复刻The Graph索引器的事件处理逻辑
  class TransferProcessor
    ZERO_ADDRESS = '0x0000000000000000000000000000000000000000'

    def initialize
      @token_parser = TokenParser.new
    end

    # 处理TransferSingle事件
    # @param event [Hash] 事件数据
    def process_transfer_single(event)
      process_transfer(
        token_id: event[:id].to_s,
        from: event[:from],
        to: event[:to],
        value: event[:value].to_i,
        tx_hash: event[:transaction_hash],
        log_index: event[:log_index],
        block_number: event[:block_number],
        block_hash: event[:block_hash],
        timestamp: event[:timestamp]
      )
    rescue ActiveRecord::RecordNotUnique => e
      Rails.logger.debug "[Indexer] 跳过重复事件: tx=#{event[:transaction_hash]}, log_index=#{event[:log_index]}"
    rescue StandardError => e
      Rails.logger.error "[Indexer] 处理TransferSingle失败: #{e.message}"
      Rails.logger.error "  event: #{event.inspect}"
      raise
    end

    # 处理TransferBatch事件
    # @param event [Hash] 事件数据
    def process_transfer_batch(event)
      ids = event[:ids] || []
      values = event[:values] || []

      ids.each_with_index do |id, index|
        process_transfer(
          token_id: id.to_s,
          from: event[:from],
          to: event[:to],
          value: values[index].to_i,
          tx_hash: event[:transaction_hash],
          log_index: event[:log_index],
          sequence_num: index,
          block_number: event[:block_number],
          block_hash: event[:block_hash],
          timestamp: event[:timestamp]
        )
      end
    rescue ActiveRecord::RecordNotUnique => e
      Rails.logger.debug "[Indexer] 跳过重复批量事件: tx=#{event[:transaction_hash]}"
    rescue StandardError => e
      Rails.logger.error "[Indexer] 处理TransferBatch失败: #{e.message}"
      raise
    end

    private

    def process_transfer(token_id:, from:, to:, value:, tx_hash:, log_index:, block_number:, block_hash:, timestamp:, sequence_num: 0)
      ActiveRecord::Base.transaction do
        # 1. 创建Transaction（同时确保Item和Instance存在）
        # 返回 [transaction_id, is_new] 以支持幂等性
        transaction_id, is_new = create_transaction(
          token_id, tx_hash, log_index, sequence_num,
          block_number, block_hash, value, from, to, timestamp
        )

        # 2. 只有新创建的Transaction才更新统计（幂等性保证）
        # 避免重复索引时累加导致数据错误
        update_item_and_balance(token_id, from, to, value, timestamp, transaction_id) if is_new
      end
    end

    # 创建交易记录
    # @return [Array<String, Boolean>] [transaction_id, is_new] 返回交易ID和是否新创建
    def create_transaction(token_id, tx_hash, log_index, sequence_num, block_number, block_hash, value, from, to, timestamp)
      # 确保Item存在
      item_id = @token_parser.get_item_id(token_id)
      ensure_item(item_id, timestamp)

      # 确保Instance存在
      ensure_instance(token_id, item_id, timestamp)

      # 创建Transaction (幂等性处理)
      transaction_id = ::ItemIndexer::Transaction.generate_id(tx_hash, log_index, sequence_num)
      is_new = false

      ::ItemIndexer::Transaction.find_or_create_by!(id: transaction_id) do |tx|
        is_new = true # 只有新创建时才执行此块
        tx.item = item_id
        tx.instance = token_id
        tx.transaction_hash = normalize_hex(tx_hash)
        tx.log_index = log_index
        tx.block_number = block_number
        tx.block_hash = normalize_hex(block_hash)
        tx.amount = value
        tx.from_address = normalize_address(from)
        tx.to_address = normalize_address(to)
        tx.timestamp = timestamp
      end

      [transaction_id, is_new]
    end

    # 确保Item存在
    def ensure_item(item_id, timestamp)
      ::ItemIndexer::Item.find_or_create_by!(id: item_id) do |item|
        item.total_supply = 0
        item.minted_amount = 0
        item.burned_amount = 0
        item.last_updated = timestamp
      end
    end

    # 确保Instance存在
    def ensure_instance(token_id, item_id, timestamp)
      instance = ::ItemIndexer::Instance.find_or_create_by!(id: token_id) do |inst|
        inst.total_supply = 0
        inst.minted_amount = 0
        inst.burned_amount = 0
        inst.item = item_id
        inst.quality = @token_parser.get_quality(token_id)
        inst.last_updated = timestamp
        # 标记需要获取metadata（仅在metadata功能启用时）
        inst.metadata_status = 'pending' if metadata_enabled?
      end

      instance
    end

    # 更新Item和Balance统计
    def update_item_and_balance(token_id, from, to, value, timestamp, transaction_id)
      item_id = @token_parser.get_item_id(token_id)
      item = ::ItemIndexer::Item.find(item_id)
      instance = ::ItemIndexer::Instance.find(token_id)

      from_normalized = from.to_s.downcase
      to_normalized = to.to_s.downcase

      # 更新发送方余额（减少）- 与The Graph一致，先处理from
      update_balance(from_normalized, to_normalized, token_id, -value, timestamp, transaction_id)

      # 更新接收方余额（增加）- 与The Graph一致，后处理to
      update_balance(to_normalized, from_normalized, token_id, value, timestamp, transaction_id)

      # 处理铸造（from == zeroAddress）
      if from_normalized == ZERO_ADDRESS
        item.total_supply += value
        item.minted_amount += value
        item.last_updated = timestamp

        instance.total_supply += value
        instance.minted_amount += value
        instance.last_updated = timestamp
      end

      # 处理销毁（to == zeroAddress）
      if to_normalized == ZERO_ADDRESS
        item.total_supply -= value
        item.burned_amount += value
        item.last_updated = timestamp

        instance.total_supply -= value
        instance.burned_amount += value
        instance.last_updated = timestamp
      end

      item.save!
      instance.save!
    end

    # 更新余额
    # 使用原子更新避免死锁（复刻The Graph的updateBalance逻辑）
    def update_balance(address, counter_party, token_id, value, timestamp, transaction_id)
      # 确保Player存在
      ::ItemIndexer::Player.ensure_player(address)

      # 计算变更量
      changes = { balance: value }

      # 根据value正负和counterParty判断操作类型
      if value.positive?
        # 增加余额
        if counter_party == ZERO_ADDRESS
          # 铸造
          changes[:minted_amount] = value
        else
          # 转入
          changes[:transferred_in_amount] = value
        end
      else
        # 减少余额（value是负数）
        if counter_party == ZERO_ADDRESS
          # 销毁
          changes[:burned_amount] = value.abs
        else
          # 转出
          changes[:transferred_out_amount] = value.abs
        end
      end

      # 原子更新（使用 upsert + 累加，避免死锁）
      ::ItemIndexer::InstanceBalance.atomic_update(token_id, address, timestamp, changes)
    end

    # 标准化十六进制字符串（确保有0x前缀，小写）
    def normalize_hex(hex_string)
      return nil if hex_string.nil?

      hex = hex_string.to_s
      # 将 ASCII-8BIT / binary 输入转为十六进制字符串
      hex = hex.unpack1('H*') if hex.encoding == Encoding::ASCII_8BIT
      hex = hex.to_s.downcase
      hex.start_with?('0x') ? hex : "0x#{hex}"
    end

    # 标准化地址（返回小写十六进制，包括零地址）
    def normalize_address(address)
      return nil if address.nil?

      normalize_hex(address)
    end

    # 检查metadata功能是否启用
    def metadata_enabled?
      Rails.application.config.x.instance_metadata.enabled
    rescue StandardError
      false
    end
  end
end
