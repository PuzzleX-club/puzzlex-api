# frozen_string_literal: true

module Indexer
  # 统计数据重算服务
  # 从 Transaction 表重新计算 Item 和 Instance 的统计数据
  # 用于修复因重复索引导致的数据错误
  class StatsRecalculator
    ZERO_ADDRESS = '0x0000000000000000000000000000000000000000'
    BATCH_SIZE = 1000

    def initialize(verbose: true)
      @verbose = verbose
    end

    # 重算所有 Item 和 Instance 的统计数据
    def recalculate_all
      log "开始重算所有统计数据..."

      # 1. 清零所有 Item 统计
      log "清零 Item 统计..."
      ::ItemIndexer::Item.update_all(total_supply: 0, minted_amount: 0, burned_amount: 0)

      # 2. 清零所有 Instance 统计
      log "清零 Instance 统计..."
      ::ItemIndexer::Instance.update_all(total_supply: 0, minted_amount: 0, burned_amount: 0)

      # 3. 从 Transaction 重新计算
      log "从 Transaction 重新计算统计数据..."
      recalculate_from_transactions

      log "统计数据重算完成!"
    end

    # 只重算指定 Item 的统计数据
    def recalculate_item(item_id)
      log "重算 Item ##{item_id} 的统计数据..."

      # 清零该 Item
      item = ::ItemIndexer::Item.find_by(id: item_id)
      return log("Item ##{item_id} 不存在") unless item

      item.update!(total_supply: 0, minted_amount: 0, burned_amount: 0)

      # 清零该 Item 下所有 Instance
      ::ItemIndexer::Instance.where(item: item_id).update_all(total_supply: 0, minted_amount: 0, burned_amount: 0)

      # 重算
      transactions = ::ItemIndexer::Transaction.where(item: item_id)
      process_transactions(transactions, single_item: true)

      # 显示结果
      item.reload
      log "重算完成: Minted=#{item.minted_amount}, Burned=#{item.burned_amount}, Total=#{item.total_supply}"
    end

    private

    def recalculate_from_transactions
      total = ::ItemIndexer::Transaction.count
      processed = 0

      # 按 item 分组处理，提高效率
      item_ids = ::ItemIndexer::Transaction.distinct.pluck(:item)
      log "共 #{item_ids.size} 个 Item 需要处理, #{total} 条 Transaction"

      item_ids.each_with_index do |item_id, index|
        transactions = ::ItemIndexer::Transaction.where(item: item_id)
        process_item_transactions(item_id, transactions)
        processed += transactions.count

        # 进度日志
        if (index + 1) % 100 == 0 || index == item_ids.size - 1
          log "进度: #{index + 1}/#{item_ids.size} Items, #{processed}/#{total} Transactions"
        end
      end
    end

    def process_item_transactions(item_id, transactions)
      item = ::ItemIndexer::Item.find_by(id: item_id)
      return unless item

      # 按 instance 分组
      instance_stats = Hash.new { |h, k| h[k] = { minted: 0, burned: 0 } }
      item_minted = 0
      item_burned = 0

      transactions.find_each do |tx|
        from = tx.from_address.to_s.downcase
        to = tx.to_address.to_s.downcase
        amount = tx.amount.to_i
        instance_id = tx.instance

        if from == ZERO_ADDRESS
          # Mint
          item_minted += amount
          instance_stats[instance_id][:minted] += amount
        end

        if to == ZERO_ADDRESS
          # Burn
          item_burned += amount
          instance_stats[instance_id][:burned] += amount
        end
      end

      # 更新 Item
      item.update!(
        minted_amount: item_minted,
        burned_amount: item_burned,
        total_supply: item_minted - item_burned
      )

      # 批量更新 Instance
      instance_stats.each do |instance_id, stats|
        instance = ::ItemIndexer::Instance.find_by(id: instance_id)
        next unless instance

        instance.update!(
          minted_amount: stats[:minted],
          burned_amount: stats[:burned],
          total_supply: stats[:minted] - stats[:burned]
        )
      end
    end

    def process_transactions(transactions, single_item: false)
      item_stats = Hash.new { |h, k| h[k] = { minted: 0, burned: 0 } }
      instance_stats = Hash.new { |h, k| h[k] = { minted: 0, burned: 0 } }

      transactions.find_each do |tx|
        from = tx.from_address.to_s.downcase
        to = tx.to_address.to_s.downcase
        amount = tx.amount.to_i
        item_id = tx.item
        instance_id = tx.instance

        if from == ZERO_ADDRESS
          item_stats[item_id][:minted] += amount
          instance_stats[instance_id][:minted] += amount
        end

        if to == ZERO_ADDRESS
          item_stats[item_id][:burned] += amount
          instance_stats[instance_id][:burned] += amount
        end
      end

      # 更新 Item
      item_stats.each do |item_id, stats|
        item = ::ItemIndexer::Item.find_by(id: item_id)
        next unless item

        item.update!(
          minted_amount: stats[:minted],
          burned_amount: stats[:burned],
          total_supply: stats[:minted] - stats[:burned]
        )
      end

      # 更新 Instance
      instance_stats.each do |instance_id, stats|
        instance = ::ItemIndexer::Instance.find_by(id: instance_id)
        next unless instance

        instance.update!(
          minted_amount: stats[:minted],
          burned_amount: stats[:burned],
          total_supply: stats[:minted] - stats[:burned]
        )
      end
    end

    def log(message)
      puts "[StatsRecalculator] #{message}" if @verbose
      Rails.logger.info "[StatsRecalculator] #{message}"
    end
  end
end
