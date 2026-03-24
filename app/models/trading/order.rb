module Trading
  class Order < ApplicationRecord

    # 关联 OrderFill
    has_many :order_fills, dependent: :destroy
    has_many :order_items, dependent: :destroy

    # 关联物品（通过 offer_item_id 关联到 catalog items）
    belongs_to :item, optional: true,
               class_name: 'CatalogData::Item',
               foreign_key: :offer_item_id,
               primary_key: :item_id

    after_commit :broadcast_depth_if_subscribed, on: [:create, :update, :destroy]
    after_create :trigger_market_matching, if: :should_trigger_matching?
    after_commit :mark_market_summary_dirty, on: [:create, :update, :destroy]
    # todo:需要添加一些对order的验证，比如conduit，offer限制等

    validates :offerer, presence: true

    # Seaport OrderType 枚举定义
    module OrderType
      FULL_OPEN = 0          # 完全开放，允许任何部分成交
      PARTIAL_OPEN = 1       # 部分开放，允许部分成交
      FULL_RESTRICTED = 2    # 完全限制，必须全部成交
      PARTIAL_RESTRICTED = 3 # 部分限制，允许部分成交但有限制
      CONTRACT = 4           # 合约订单
    end

    # 平台只允许的订单类型
    ALLOWED_ORDER_TYPES = [OrderType::FULL_RESTRICTED, OrderType::PARTIAL_RESTRICTED].freeze

    # 订单类型描述
    ORDER_TYPE_DESCRIPTIONS = {
      OrderType::FULL_OPEN => '完全开放',
      OrderType::PARTIAL_OPEN => '部分开放',
      OrderType::FULL_RESTRICTED => '完全限制（必须全部成交）',
      OrderType::PARTIAL_RESTRICTED => '部分限制（允许部分成交）',
      OrderType::CONTRACT => '合约订单'
    }.freeze

    # 验证订单类型
    validates :order_type, inclusion: {
      in: ALLOWED_ORDER_TYPES,
      message: "只允许 FULL_RESTRICTED(2) 或 PARTIAL_RESTRICTED(3) 类型"
    }

    # 判断是否允许部分成交
    def allows_partial_fill?
      order_type == OrderType::PARTIAL_RESTRICTED || order_type == OrderType::PARTIAL_OPEN
    end

    # 判断是否必须全部成交
    def requires_full_fill?
      order_type == OrderType::FULL_RESTRICTED
    end

    # 获取订单类型描述
    def order_type_description
      ORDER_TYPE_DESCRIPTIONS[order_type] || "未知类型(#{order_type})"
    end

    # Seaport ItemType 枚举定义
    module ItemType
      NATIVE = 0                    # ETH on mainnet, MATIC on polygon, etc.
      ERC20 = 1                      # ERC20 tokens
      ERC721 = 2                     # ERC721 NFTs
      ERC1155 = 3                    # ERC1155 NFTs
      ERC721_WITH_CRITERIA = 4      # ERC721 with multiple tokenIds support
      ERC1155_WITH_CRITERIA = 5     # ERC1155 with multiple ids support
    end

    # ItemType 描述
    ITEM_TYPE_DESCRIPTIONS = {
      ItemType::NATIVE => 'Native Token (ETH/MATIC)',
      ItemType::ERC20 => 'ERC20 Token',
      ItemType::ERC721 => 'ERC721 NFT',
      ItemType::ERC1155 => 'ERC1155 NFT',
      ItemType::ERC721_WITH_CRITERIA => 'ERC721 Collection',
      ItemType::ERC1155_WITH_CRITERIA => 'ERC1155 Collection'
    }.freeze

    # 判断订单是否包含原生代币（不支持match操作）
    def contains_native_token?
      # 对于卖单，检查 consideration（收款方式）
      # 对于买单，检查 offer（支付方式）
      if order_direction == 'List'
        consideration_item_type == ItemType::NATIVE
      elsif order_direction == 'Offer'
        offer_item_type == ItemType::NATIVE
      else
        false
      end
    end

    # 获取 offer ItemType 描述
    def offer_item_type_description
      return nil unless offer_item_type
      ITEM_TYPE_DESCRIPTIONS[offer_item_type] || "未知类型(#{offer_item_type})"
    end

    # 获取 consideration ItemType 描述
    def consideration_item_type_description
      return nil unless consideration_item_type
      ITEM_TYPE_DESCRIPTIONS[consideration_item_type] || "未知类型(#{consideration_item_type})"
    end

    # TODO: 添加NFT合约地址验证
    # - 验证订单中的NFT合约地址是否在系统支持的列表中
    # - 可以选择警告或拒绝不支持的合约
    # - 从 Rails.application.config.x.blockchain.nft_contract_address 读取配置

    # 链上状态枚举定义
    enum onchain_status: {
      pending: 'pending',
      validated: 'validated',
      partially_filled: 'partially_filled',
      filled: 'filled',
      cancelled: 'cancelled'
    }, _prefix: :onchain

    # 链下状态枚举定义
    enum offchain_status: {
      active: 'active',           # 活跃状态
      over_matched: 'over_matched', # 超额匹配
      expired: 'expired',         # 过期
      paused: 'paused',           # 暂停
      matching: 'matching',       # 撮合中
      validation_failed: 'validation_failed', # 验证失败（余额/签名/Zone等）
      closed: 'closed',           # 终态（链上成交/取消后关闭）
      match_failed: 'match_failed' # 终态（撮合失败达到上限）
    }, _prefix: :offchain

    ACTIVE_ONCHAIN_STATUSES = %w[pending validated partially_filled].freeze
    ACTIVE_OFFCHAIN_STATUSES = %w[active matching].freeze

    scope :active_market_orders, lambda {
      where(onchain_status: ACTIVE_ONCHAIN_STATUSES, offchain_status: ACTIVE_OFFCHAIN_STATUSES)
    }

    # 链下状态中文描述映射
    OFF_CHAIN_STATUS_DESCRIPTIONS = {
      'active' => '活跃',
      'over_matched' => '超额匹配',
      'expired' => '过期',
      'paused' => '暂停',
      'matching' => '撮合中',
      'validation_failed' => '验证失败',
      'closed' => '已关闭',
      'match_failed' => '撮合失败'
    }.freeze

    # 验证失败原因描述映射
    VALIDATION_REASON_DESCRIPTIONS = {
      'balance_insufficient' => '货币余额不足',
      'token_insufficient' => 'NFT 余额不足',
      'expired' => '订单已过期',
      'not_yet_valid' => '订单尚未生效',
      'signature_invalid' => '签名无效',
      'zone_restriction_failed' => '代币不在白名单中',
      'native_token_unsupported' => '不支持原生代币',
      'validation_error' => '验证异常'
    }.freeze

    # 链上状态中文描述映射（保持与现有逻辑一致）
    ON_CHAIN_STATUS_DESCRIPTIONS = {
      'pending' => '待验证',
      'validated' => '已验证',
      'partially_filled' => '部分成交',
      'filled' => '已成交',
      'cancelled' => '已取消'
    }.freeze

    # 检查订单是否应该在前端显示
    def should_display?
      # 链上状态必须是活跃状态
      return false unless %w[pending validated partially_filled].include?(onchain_status)

      # 如果有链下状态，检查是否为显示状态
      if offchain_status.present?
        return false if %w[expired paused closed match_failed].include?(offchain_status)
        # matching状态的订单应该显示但标记为"撮合中"
      end

      true
    end

    # 获取链下状态的中文描述
    def offchain_status_description
      return nil if offchain_status.blank?
      OFF_CHAIN_STATUS_DESCRIPTIONS[offchain_status] || offchain_status
    end

    # 获取链上状态的中文描述
    def on_chain_status_description
      ON_CHAIN_STATUS_DESCRIPTIONS[onchain_status] || onchain_status
    end

    # 获取综合状态描述
    def combined_status_description
      on_chain_desc = on_chain_status_description

      if offchain_status.present?
        off_chain_desc = offchain_status_description
        "#{on_chain_desc} (#{off_chain_desc})"
      else
        on_chain_desc
      end
    end

    # 获取状态优先级（用于排序）
    def status_priority
      # 链上状态优先级
      on_chain_priority = case onchain_status
                         when 'validated' then 1
                         when 'partially_filled' then 2
                         when 'pending' then 3
                         when 'filled' then 4
                         when 'cancelled' then 5
                         else 6
                         end

      # 链下状态优先级调整
      off_chain_adjustment = case offchain_status
                            when 'active', nil then 0
                            when 'over_matched' then 10
                            when 'expired' then 20
                            when 'paused' then 30
                            when 'closed' then 40
                            when 'match_failed' then 50
                            else 40
                            end

      on_chain_priority + off_chain_adjustment
    end

    private

    def mark_market_summary_dirty
      return if market_id.blank?

      MarketData::MarketSummaryStore.mark_dirty(market_id)
    end

    def broadcast_depth_if_subscribed
      return unless market_id.present?

      limits = Realtime::SubscriptionGuard.depth_limits_for_market(market_id)
      return if limits.empty?

      Jobs::Orders::DepthBroadcastJob.perform_async(market_id)  # 一次性异步广播
    end

          # 新订单创建时触发匹配
      def trigger_market_matching
        Rails.logger.info "[ORDER_TRIGGER] 新订单创建 - ID: #{id}, 市场: #{market_id}, 方向: #{order_direction}"

        # 防冲突检查：避免频繁触发
        if recently_triggered?(market_id)
          Rails.logger.info "[ORDER_TRIGGER] 跳过触发 - 市场 #{market_id} 3秒内已触发过"
          return
        end

        # 记录触发时间并延迟1秒执行
        record_trigger_time(market_id)
        Jobs::Matching::Worker.perform_in(1.second, market_id, 'new_order')

        Rails.logger.info "[ORDER_TRIGGER] 调度撮合 - 市场: #{market_id}, 延迟: 1秒, 订单ID: #{id}"
      rescue => e
        Rails.logger.error "[ORDER_TRIGGER] 触发匹配失败: #{e.message}"
      end

      # 检查是否最近已经触发过
      def recently_triggered?(market_id)
        trigger_key = "order_trigger:#{market_id}"
        last_trigger = Redis.current.get(trigger_key)

        if last_trigger
          last_time = Time.at(last_trigger.to_f)
          # 如果3秒内已经触发过，则跳过
          return true if Time.current - last_time < 3.seconds
        end

        false
      end

      # 记录触发时间
      def record_trigger_time(market_id)
        trigger_key = "order_trigger:#{market_id}"
        Redis.current.set(trigger_key, Time.current.to_f, ex: 5)
      end

    # 判断是否需要触发匹配
    def should_trigger_matching?
      # 只有validated状态的订单才触发匹配
      onchain_status == 'validated' && !is_cancelled?
    end

  end
end
