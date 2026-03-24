# frozen_string_literal: true

module Client
  module Explorer
    class PlayersController < BaseController
      # GET /api/explorer/players
      # 获取玩家列表（按持有量排序）
      def index
        # 聚合所有玩家的持有数据
        players = ItemIndexer::InstanceBalance
                   .where("balance > 0")
                   .select(
                     "player",
                     "COUNT(DISTINCT instance) as unique_items_count",
                     "SUM(balance) as total_balance",
                     "MAX(timestamp) as last_active"
                   )
                   .group(:player)
                   .order("total_balance DESC")

        # 分页
        page_params = pagination_params
        total_count = players.length
        players_page = players.offset((page_params[:page] - 1) * page_params[:per_page])
                              .limit(page_params[:per_page])

        players_data = players_page.map do |player|
          {
            address: player.player,
            address_short: format_address(player.player),
            unique_items_count: player.unique_items_count,
            total_balance: player.total_balance.to_s,
            last_active: player.last_active
          }
        end

        render_success({
          players: players_data,
          meta: {
            current_page: page_params[:page],
            per_page: page_params[:per_page],
            total_count: total_count,
            total_pages: (total_count.to_f / page_params[:per_page]).ceil,
            has_more: page_params[:page] < (total_count.to_f / page_params[:per_page]).ceil
          }
        })
      end

      # GET /api/explorer/players/:address
      # 获取单个玩家详情
      def show
        address = params[:address].to_s.downcase

        # 检查玩家是否存在
        player = ItemIndexer::Player.find_by(id: address)
        if player.nil?
          render_error("玩家不存在: #{address}", :not_found)
          return
        end

        # 统计玩家数据
        balances = player.instance_balances.where("balance > 0")
        total_balance_count = balances.count
        instances_table = ItemIndexer::Instance.table_name
        balances_table = ItemIndexer::InstanceBalance.table_name
        unique_items = balances.joins("INNER JOIN #{instances_table} ON #{instances_table}.id = #{balances_table}.instance")
                               .select("DISTINCT #{instances_table}.item")
                               .count
        last_active = balances.maximum(:timestamp)

        # 获取第一笔交易时间（first_seen）
        first_seen = ItemIndexer::Transaction
                      .where("from_address = ? OR to_address = ?", address, address)
                      .minimum(:timestamp)

        render_success({
          player: {
            address: address,
            address_short: format_address(address),
            total_balance_count: total_balance_count,
            unique_items_count: unique_items,
            first_seen: first_seen,
            last_active: last_active
          }
        })
      end

      # GET /api/explorer/players/:address/balances
      # 获取玩家持有的所有NFT余额
      def balances
        address = params[:address].to_s.downcase

        # 检查玩家是否存在
        player = ItemIndexer::Player.find_by(id: address)
        if player.nil?
          render_error("玩家不存在: #{address}", :not_found)
          return
        end

        # 获取玩家余额，按物品分组
        balances = player.instance_balances
                         .includes(instance_record: [:item_record, :metadata])
                         .where("balance > 0")
                         .order(balance: :desc)

        # 分页
        page_params = pagination_params
        total_count = balances.count
        balances = balances.offset((page_params[:page] - 1) * page_params[:per_page])
                           .limit(page_params[:per_page])

        balances_data = balances.map do |bal|
          instance = bal.instance_record
          {
            instance_id: bal.instance,
            item_id: instance.item,
            quality: instance.quality,
            balance: bal.balance.to_s,
            minted_amount: bal.minted_amount.to_s,
            transferred_in_amount: bal.transferred_in_amount.to_s,
            transferred_out_amount: bal.transferred_out_amount.to_s,
            burned_amount: bal.burned_amount.to_s,
            last_updated: bal.timestamp,
            metadata: instance.metadata ? {
              name: instance.metadata.name,
              image: instance.metadata.image
            } : nil,
            item_info: fetch_item_info(instance.item)
          }
        end

        render_success({
          player: address,
          balances: balances_data,
          meta: {
            current_page: page_params[:page],
            per_page: page_params[:per_page],
            total_count: total_count,
            total_pages: (total_count.to_f / page_params[:per_page]).ceil,
            has_more: page_params[:page] < (total_count.to_f / page_params[:per_page]).ceil
          }
        })
      end

      # GET /api/explorer/players/:address/transfers
      # 获取玩家的转移历史
      def transfers
        address = params[:address].to_s.downcase

        # 检查玩家是否存在
        player = ItemIndexer::Player.find_by(id: address)
        if player.nil?
          render_error("玩家不存在: #{address}", :not_found)
          return
        end

        transfers = ItemIndexer::Transaction
                     .where("from_address = ? OR to_address = ?", address, address)
                     .order(timestamp: :desc, block_number: :desc)

        # 筛选类型
        if params[:type].present? && params[:type] != 'all'
          zero_addr = '0x0000000000000000000000000000000000000000'
          case params[:type]
          when 'mint'
            transfers = transfers.where(from_address: [zero_addr, nil, ''], to_address: address)
          when 'burn'
            transfers = transfers.where(from_address: address, to_address: [zero_addr, nil, ''])
          when 'transfer'
            transfers = transfers.where.not(from_address: [zero_addr, nil, ''])
                                 .where.not(to_address: [zero_addr, nil, ''])
          end
        end

        # 分页
        page_params = pagination_params
        total_count = transfers.count
        transfers = transfers.offset((page_params[:page] - 1) * page_params[:per_page])
                             .limit(page_params[:per_page])

        transfers_data = transfers.map do |tx|
          {
            id: tx.id,
            type: transaction_type(tx.from_address, tx.to_address),
            direction: tx.from_address.to_s.downcase == address ? 'out' : 'in',
            item_id: tx.item,
            instance_id: tx.instance,
            from_address: tx.from_address,
            from_address_short: format_address(tx.from_address),
            to_address: tx.to_address,
            to_address_short: format_address(tx.to_address),
            amount: tx.amount.to_s,
            transaction_hash: tx.transaction_hash,
            block_number: tx.block_number,
            timestamp: tx.timestamp,
            item_info: fetch_item_info(tx.item)
          }
        end

        render_success({
          player: address,
          transfers: transfers_data,
          meta: {
            current_page: page_params[:page],
            per_page: page_params[:per_page],
            total_count: total_count,
            total_pages: (total_count.to_f / page_params[:per_page]).ceil,
            has_more: page_params[:page] < (total_count.to_f / page_params[:per_page]).ceil
          }
        })
      end
    end
  end
end
