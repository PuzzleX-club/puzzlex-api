# frozen_string_literal: true

# 统一日志采集配置 + 默认订阅注册
require "eth"

def compute_topic(signature)
  "0x" + Eth::Util.keccak256(signature).unpack1("H*")
end

def upsert_subscription!(handler_key:, abi_key:, addresses:, topic_signatures:, start_block:, block_window:)
  topic0s = topic_signatures.map { |sig| compute_topic(sig) }
  mapping = topic0s.zip(topic_signatures.map { |sig| sig.split("(").first }).to_h

  Onchain::EventSubscription.find_or_initialize_by(handler_key: handler_key).tap do |sub|
    sub.abi_key = abi_key
    sub.addresses = addresses
    sub.topics = [topic0s]
    sub.topic0_mapping = mapping
    sub.start_block = start_block
    sub.block_window = block_window
    sub.save!
  end
end

# 延迟初始化：等待 Rails 完全启动后再执行
Rails.application.config.after_initialize do
  begin
    # 检查表是否存在（迁移可能尚未执行）
    # 注意：数据库不存在时会抛出 NoDatabaseError，需要容错处理
    unless Onchain::EventSubscription.table_exists?
      Rails.logger.warn "[EventCollector] onchain_event_subscriptions表不存在，跳过订阅初始化（请先运行 rails db:migrate）"
      next
    end

    # 环境变量开关控制
    order_events_enabled = ENV.fetch('LOG_COLLECTOR_ORDER_EVENTS_ENABLED', 'true') == 'true'
    item_indexer_enabled = ENV.fetch('LOG_COLLECTOR_ITEM_INDEXER_ENABLED', 'true') == 'true'

    # 记录当前索引器启用状态
    Rails.logger.info "[EventCollector] 索引器启用状态: order_events=#{order_events_enabled}, item_indexer=#{item_indexer_enabled}"

    # 市场事件订阅（Seaport）- 可通过环境变量控制
    if order_events_enabled
      seaport_address = Rails.application.config.x.blockchain.seaport_contract_address
      seaport_start = Rails.application.config.x.blockchain.event_listener_genesis_block || 0
      seaport_window = 90

      upsert_subscription!(
        handler_key: "order_events",
        abi_key: "seaport",
        addresses: [seaport_address],
        topic_signatures: [
          "OrderFulfilled(bytes32,address,address,address,(uint8,address,uint256,uint256)[],(uint8,address,uint256,uint256,address)[])",
          "OrderValidated(bytes32,tuple)",
          "OrderCancelled(bytes32,address,address)",
          "OrdersMatched(bytes32[])",
          "CounterIncremented(uint256,address indexed)"
        ],
        start_block: seaport_start,
        block_window: seaport_window
      )
      Rails.logger.info "[EventCollector] ✅ 市场事件订阅已启用 (order_events)"
    else
      Rails.logger.info "[EventCollector] ⏸️ 市场事件订阅已禁用 (order_events)"
    end

    # NFT 事件订阅（ERC1155）- 可通过环境变量控制
    if item_indexer_enabled
      nft_cfg = Rails.application.config.x.indexer
      nft_window = nft_cfg.block_batch_size || 90

      # 检查NFT合约地址是否配置
      if nft_cfg.contract_address.present?
        upsert_subscription!(
          handler_key: "item_indexer",
          abi_key: "erc1155",
          addresses: [nft_cfg.contract_address],
          topic_signatures: [
            "TransferSingle(address,address,address,uint256,uint256)",
            "TransferBatch(address,address,address,uint256[],uint256[])"
          ],
          start_block: nft_cfg.start_block,
          block_window: nft_window
        )
        Rails.logger.info "[EventCollector] ✅ NFT事件订阅已启用 (item_indexer), 合约: #{nft_cfg.contract_address}"
      else
        Rails.logger.warn "[EventCollector] ⚠️ NFT事件订阅启用但合约地址未配置 (item_indexer)"
      end
    else
      Rails.logger.info "[EventCollector] ⏸️ NFT事件订阅已禁用 (item_indexer)"
    end

    # 统计启用的索引器数量
    enabled_handlers = []
    enabled_handlers << "order_events" if order_events_enabled
    enabled_handlers << "item_indexer" if item_indexer_enabled

    Rails.logger.info "[EventCollector] 订阅配置初始化完成，已启用索引器: #{enabled_handlers.join(', ')} (共#{enabled_handlers.length}个)"
  rescue ActiveRecord::NoDatabaseError => e
    Rails.logger.warn "[EventCollector] 数据库不存在，跳过订阅初始化（请先运行 rails db:create）"
  rescue => e
    Rails.logger.error "[EventCollector] 初始化订阅失败: #{e.class} - #{e.message}"
    Rails.logger.error e.backtrace.first(5).join("\n") if e.backtrace
  end
end
