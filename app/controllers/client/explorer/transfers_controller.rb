# frozen_string_literal: true

module Client
  module Explorer
    class TransfersController < BaseController
      # GET /api/explorer/transfers
      # 获取转移记录列表（支持多种筛选）
      def index
        transfers = ItemIndexer::Transaction.all

        # 筛选：按物品
        if params[:item_id].present?
          transfers = transfers.where(item: params[:item_id])
        end

        # 筛选：按Instance
        if params[:instance_id].present?
          transfers = transfers.where(instance: params[:instance_id])
        end

        # 筛选：按地址（from或to）
        if params[:address].present?
          address = params[:address].to_s.downcase
          transfers = transfers.where("from_address = ? OR to_address = ?", address, address)
        end

        # 筛选：按from_address
        if params[:from_address].present?
          transfers = transfers.where(from_address: params[:from_address].to_s.downcase)
        end

        # 筛选：按to_address
        if params[:to_address].present?
          transfers = transfers.where(to_address: params[:to_address].to_s.downcase)
        end

        # 筛选：按交易哈希
        if params[:transaction_hash].present?
          transfers = transfers.where(transaction_hash: params[:transaction_hash].to_s.downcase)
        end

        # 筛选：按类型
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

        # 时间范围筛选
        if params[:start_time].present? || params[:end_time].present?
          time_range = time_range_params
          transfers = transfers.where(timestamp: time_range[:start_time].to_i..time_range[:end_time].to_i)
        end

        # 排序：按时间倒序
        transfers = transfers.order(timestamp: :desc, block_number: :desc)

        # 分页
        page_params = pagination_params
        total_count = transfers.count
        transfers = transfers.offset((page_params[:page] - 1) * page_params[:per_page])
                             .limit(page_params[:per_page])

        # 预加载item_info
        transfers_data = transfers.map { |tx| format_transfer_with_item(tx) }

        render_success({
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

      # GET /api/explorer/transfers/:id
      # 获取单条转移记录详情
      def show
        transfer = ItemIndexer::Transaction.find_by(id: params[:id])

        if transfer.nil?
          render_error("转移记录不存在: #{params[:id]}", :not_found)
          return
        end

        render_success({
          transfer: format_transfer_with_item(transfer)
        })
      end

      private

      def format_transfer_with_item(tx)
        {
          id: tx.id,
          type: transaction_type(tx.from_address, tx.to_address),
          item_id: tx.item,
          instance_id: tx.instance,
          from_address: tx.from_address,
          from_address_short: format_address(tx.from_address),
          to_address: tx.to_address,
          to_address_short: format_address(tx.to_address),
          amount: tx.amount.to_s,
          transaction_hash: tx.transaction_hash,
          block_number: tx.block_number,
          block_hash: tx.block_hash,
          log_index: tx.log_index,
          timestamp: tx.timestamp,
          item_info: fetch_item_info(tx.item)
        }
      end
    end
  end
end
