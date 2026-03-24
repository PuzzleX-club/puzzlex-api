# frozen_string_literal: true

module Client
  module Market
    module Trading
      class MarketsController < ::Client::ProtectedController
        # GET /api/market/trading/markets/:id/summary
        # 获取单个市场的摘要信息
        def summary
          market_id = params[:id].to_i

          if market_id <= 0
            render_error('Invalid market_id', :bad_request)
            return
          end

          force_refresh = params[:force_refresh] == 'true'

          begin
            summary_record = ::Trading::MarketSummary.find_by(market_id: market_id.to_s)

            if force_refresh || summary_record.nil? || summary_record.dirty?
              summary = MarketData::MarketSummaryService.new.call(market_id)
              MarketData::MarketSummaryStore.upsert_summary(summary)
              RuntimeCache::MarketDataStore.store_market_summary(market_id, summary)
              summary_record = ::Trading::MarketSummary.find_by(market_id: market_id.to_s)
            end

            if summary_record
              render_success(MarketData::MarketSummaryStore.serialize(summary_record))
            else
              render_error('Market not found', :not_found)
            end
          rescue => e
            Rails.logger.error "[MarketsController#summary] Error: #{e.message}"
            render_error('Failed to fetch market summary', :internal_server_error)
          end
        end

        # GET /api/market/trading/markets/summary_list
        # 批量获取市场摘要列表
        def summary_list
          # 解析 ids 参数
          ids_param = params[:ids]
          page = params[:page].to_i
          per = params[:per].to_i

          market_ids = []

          filters = Catalog::ItemFilterParams.from_params(params)
          filters_present = filters.values.any?(&:present?)

          if ids_param.present?
            # 优先使用 ids 参数
            market_ids = ids_param.split(',').map(&:to_i).select { |id| id > 0 }

            if market_ids.empty?
              render_error('Invalid ids parameter', :bad_request)
              return
            end
          elsif page > 0 && per > 0
            if filters_present
              # 使用筛选条件（从订单表获取符合条件的市场ID）
              active_orders = ::Trading::Order.active_market_orders

              filtered_orders = Catalog::ItemFilterService.apply_filters(active_orders, **filters)
              active_market_query = filtered_orders.select(:market_id).distinct

              total = active_market_query.count
              offset = (page - 1) * per
              market_ids = active_market_query.offset(offset).limit(per).pluck(:market_id)
            else
              # 使用分页参数（优先从 Redis ZSET 获取市场ID）
              total = Redis.current.zcard(RuntimeCache::Keyspace.summary_markets_key)
              offset = (page - 1) * per
              market_ids = Redis.current.zrevrange(
                RuntimeCache::Keyspace.summary_markets_key,
                offset,
                offset + per - 1
              ).map(&:to_i)

              if market_ids.empty?
                total = MarketData::MarketSummaryStore.total_count
                market_ids = MarketData::MarketSummaryStore.fetch_page(page, per).map { |record| record.market_id.to_i }
              end
            end

            if market_ids.empty?
              render_success({ markets: [], pagination: { page: page, per: per, total: total } })
              return
            end
          else
            render_error('Missing ids or pagination parameters', :bad_request)
            return
          end

          force_refresh = params[:force_refresh] == 'true'

          begin
            records_by_id = MarketData::MarketSummaryStore.fetch_summaries(market_ids)

            refresh_ids = []
            missing_ids = []

            market_ids.each do |id|
              record = records_by_id[id.to_s]
              if record.nil?
                missing_ids << id
              elsif record.dirty? || force_refresh
                refresh_ids << id
              end
            end

            if refresh_ids.present?
              refreshed = MarketData::MarketSummaryService.new.batch_call(refresh_ids)
              MarketData::MarketSummaryStore.upsert_summaries(refreshed.values)
              RuntimeCache::MarketDataStore.store_market_summaries(refreshed)
            end

            if missing_ids.present?
              fresh = MarketData::MarketSummaryService.new.batch_call(missing_ids)
              MarketData::MarketSummaryStore.upsert_summaries(fresh.values)
              RuntimeCache::MarketDataStore.store_market_summaries(fresh)
            end

            records_by_id = MarketData::MarketSummaryStore.fetch_summaries(market_ids)
            ordered_markets = market_ids.map { |id| MarketData::MarketSummaryStore.serialize(records_by_id[id.to_s]) }.compact
            response_data = {
              markets: ordered_markets,
              ids: ordered_markets.map { |market| market[:market_id] }
            }

            # 如果是分页查询，添加分页信息
            if page > 0 && per > 0
              response_data[:pagination] = {
                page: page,
                per: per,
                total: total
              }
            end

            render_success(response_data)
          rescue => e
            Rails.logger.error "[MarketsController#summary_list] Error: #{e.message}"
            render_error('Failed to fetch market summaries', :internal_server_error)
          end
        end

        private

        # Strong parameters
        def market_summary_params
          params.permit(:ids, :page, :per, :force_refresh)
        end
      end
    end
  end
end
