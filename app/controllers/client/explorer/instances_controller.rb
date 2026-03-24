# frozen_string_literal: true

module Client
  module Explorer
    class InstancesController < BaseController
      # GET /api/explorer/instances
      # 获取所有Instance列表（分页）
      def index
        instances = ItemIndexer::Instance.includes(:metadata, :item_record)

        # 筛选：按item_id
        if params[:item_id].present?
          instances = instances.where(item: params[:item_id])
        end

        # 排序：按last_updated倒序
        instances = instances.order(last_updated: :desc)

        # 分页
        page_params = pagination_params
        total_count = instances.count
        instances = instances.offset((page_params[:page] - 1) * page_params[:per_page])
                             .limit(page_params[:per_page])

        instances_data = instances.map { |inst| format_instance_detail(inst) }

        render_success({
          instances: instances_data,
          meta: {
            current_page: page_params[:page],
            per_page: page_params[:per_page],
            total_count: total_count,
            total_pages: (total_count.to_f / page_params[:per_page]).ceil,
            has_more: page_params[:page] < (total_count.to_f / page_params[:per_page]).ceil
          }
        })
      end

      # GET /api/explorer/instances/:id
      # 获取单个Instance详情
      def show
        instance = ItemIndexer::Instance.includes(:metadata, :nft_attributes, :item_record)
                                              .find_by(id: params[:id])

        if instance.nil?
          render_error("Instance不存在: #{params[:id]}", :not_found)
          return
        end

        # 统计持有者数
        holder_count = instance.instance_balances.where("balance > 0").count

        render_success({
          instance: format_instance_detail(instance),
          stats: {
            holder_count: holder_count
          },
          attributes: format_attributes(instance.nft_attributes)
        })
      end

      # GET /api/explorer/instances/:id/balances
      # 获取Instance的持有者余额分布
      def balances
        instance = ItemIndexer::Instance.find_by(id: params[:id])

        if instance.nil?
          render_error("Instance不存在: #{params[:id]}", :not_found)
          return
        end

        balances = instance.instance_balances
                           .where("balance > 0")
                           .order(balance: :desc)

        # 分页
        page_params = pagination_params
        total_count = balances.count
        balances = balances.offset((page_params[:page] - 1) * page_params[:per_page])
                           .limit(page_params[:per_page])

        balances_data = balances.map do |bal|
          {
            player: bal.player,
            player_short: format_address(bal.player),
            balance: bal.balance.to_s,
            minted_amount: bal.minted_amount.to_s,
            transferred_in_amount: bal.transferred_in_amount.to_s,
            transferred_out_amount: bal.transferred_out_amount.to_s,
            burned_amount: bal.burned_amount.to_s,
            last_updated: bal.timestamp
          }
        end

        render_success({
          instance_id: instance.id,
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

      # GET /api/explorer/instances/:id/transfers
      # 获取Instance的转移历史
      def transfers
        instance = ItemIndexer::Instance.find_by(id: params[:id])

        if instance.nil?
          render_error("Instance不存在: #{params[:id]}", :not_found)
          return
        end

        transfers = instance.transactions.order(timestamp: :desc, block_number: :desc)

        # 筛选类型
        if params[:type].present? && params[:type] != 'all'
          zero_addr = '0x0000000000000000000000000000000000000000'
          case params[:type]
          when 'mint'
            transfers = transfers.where(from_address: [zero_addr, nil, ''])
          when 'burn'
            transfers = transfers.where(to_address: [zero_addr, nil, ''])
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

        transfers_data = transfers.map { |tx| format_transfer(tx) }

        render_success({
          instance_id: instance.id,
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

      private

      def format_instance_detail(instance)
        metadata = instance.metadata
        {
          id: instance.id,
          item_id: instance.item,
          quality: instance.quality,
          total_supply: instance.total_supply.to_s,
          minted_amount: instance.minted_amount.to_s,
          burned_amount: instance.burned_amount.to_s,
          last_updated: instance.last_updated,
          metadata_status: instance.metadata_status,
          metadata: metadata ? {
            name: metadata.name,
            description: metadata.description,
            image: metadata.image,
            background_color: metadata.background_color
          } : nil,
          item_info: fetch_item_info(instance.item)
        }
      end

      def format_attributes(attributes)
        return [] if attributes.blank?

        attributes.map do |attr|
          {
            trait_type: attr.trait_type,
            value: attr.value_string || attr.value_numeric&.to_s,
            display_type: attr.display_type,
            is_fungible: attr.is_fungible
          }
        end
      end

      def format_transfer(tx)
        {
          id: tx.id,
          type: transaction_type(tx.from_address, tx.to_address),
          from_address: tx.from_address,
          from_address_short: format_address(tx.from_address),
          to_address: tx.to_address,
          to_address_short: format_address(tx.to_address),
          amount: tx.amount.to_s,
          transaction_hash: tx.transaction_hash,
          block_number: tx.block_number,
          block_hash: tx.block_hash,
          timestamp: tx.timestamp
        }
      end
    end
  end
end
