module Client
  module Market
    module Trading
      class TradesController < ::Client::ProtectedController
        # 有条件的认证：只有涉及用户数据时才需要
        before_action :conditional_authenticate!, only: [:history, :statistics]
        # 强制认证：导出和详情需要用户登录
        before_action :authenticate_request!, only: [:export, :show]

        # GET /api/market/trading/trades/history
        def history
          begin
            # 从参数中获取筛选条件
            market_id = params[:market_id]
            order_type = params[:order_type]
            user_filter = params[:user_filter] || 'all'
            start_date = params[:start_date]
            end_date = params[:end_date]
            limit = [[params[:limit].to_i, 10].max, 100].min
            last_id = params[:last_id].presence

            Rails.logger.info "交易历史查询参数: market_id=#{market_id}, order_type=#{order_type}, user_filter=#{user_filter}, limit=#{limit}, last_id=#{last_id}"

            # 构建基础查询
            query = build_base_query(market_id, order_type, user_filter, start_date, end_date)

            # 分页查询（避免 count，使用 limit+1 判断 has_more）
            query = query.order(id: :desc)
            query = query.where("trading_order_fills.id < ?", last_id) if last_id

            trades = query.limit(limit + 1)

            trades = trades.select(
              :id,
              :transaction_hash,
              :market_id,
              :order_id,
              :order_item_id,
              :filled_amount,
              :created_at,
              :block_timestamp,
              :buyer_address,
              :seller_address,
              :price_distribution
            )

            has_more = trades.length > limit
            trades = trades.first(limit)
            last_id_value = trades.last&.id

            orders_by_id, order_items_by_id = preload_trade_associations(trades)

            # 格式化数据
            formatted_trades = format_trade_data(
              trades,
              orders_by_id: orders_by_id,
              order_items_by_id: order_items_by_id
            )

            render_success(
              {
                trades: formatted_trades,
                pagination: {
                  limit: limit,
                  has_more: has_more,
                  last_id: last_id_value
                }
              },
              '获取交易历史成功'
            )

          rescue => e
            Rails.logger.error "获���交易历史失败: #{e.message}"
            Rails.logger.error e.backtrace.join("\n")
            render_error("获取交易历史失败: #{e.message}", :internal_server_error)
          end
        end

        # GET /api/market/trading/trades/statistics
        def statistics
          begin
            market_id = params[:market_id]
            user_filter = params[:user_filter] || 'all'
            start_date = params[:start_date]
            end_date = params[:end_date]

            Rails.logger.info "交易统计查询参数: market_id=#{market_id}, user_filter=#{user_filter}"

            # 构建查询
            query = build_base_query(market_id, nil, user_filter, start_date, end_date)

            # 计算统计数据
            statistics = calculate_statistics(query, user_filter)

            render_success(statistics, '获取交易统计成功')

          rescue => e
            Rails.logger.error "获取交易统计失败: #{e.message}"
            Rails.logger.error e.backtrace.join("\n")
            render_error("获取交易统计失败: #{e.message}", :internal_server_error)
          end
        end

        # GET /api/market/trading/trades/:trade_hash
        def show
          begin
            trade_hash = params[:trade_hash] || params[:id]

            Rails.logger.info "查询交易详情: trade_hash=#{trade_hash}"

            # 查找交易记录
            trade = ::Trading::OrderFill.joins(:order)
                                      .where(transaction_hash: trade_hash)
                                      .first

            unless trade
              render_error("未找到指定的交易记录", :not_found)
              return
            end

            # 格式化详细数据
            trade_detail = format_trade_detail(trade)

            render_success(trade_detail, '获取交易详情成功')

          rescue => e
            Rails.logger.error "获取交易详情失败: #{e.message}"
            Rails.logger.error e.backtrace.join("\n")
            render_error("获取交易详情失败: #{e.message}", :internal_server_error)
          end
        end

        # GET /api/market/trading/trades/export
        def export
          begin
            market_id = params[:market_id]
            user_filter = params[:user_filter] || 'my_trades'
            start_date = params[:start_date]
            end_date = params[:end_date]
            limit = [[params[:limit].to_i, 100].max, 5000].min

            Rails.logger.info "导出交易记录: market_id=#{market_id}, user_filter=#{user_filter}, limit=#{limit}"

            # 只允许导出用户自己的交易记录
            unless ['my_trades', 'my_buys', 'my_sells'].include?(user_filter)
              render_error("导出功能仅支持个人交易记录", :bad_request)
              return
            end

            # 构建查询
            query = build_base_query(market_id, nil, user_filter, start_date, end_date)
            trades = query.limit(limit).order(id: :desc)
            orders_by_id, order_items_by_id = preload_trade_associations(trades)

            # 格式化导出数据
            export_data = format_export_data(trades, orders_by_id: orders_by_id, order_items_by_id: order_items_by_id)

            render_success(
              {
                trades: export_data,
                export_info: {
                  total_records: export_data.length,
                  export_date: Time.current.to_i,
                  market_id: market_id,
                  date_range: {
                    start: start_date,
                    end: end_date
                  }
                }
              },
              '导出交易记录成功'
            )

          rescue => e
            Rails.logger.error "导出交易记录失败: #{e.message}"
            Rails.logger.error e.backtrace.join("\n")
            render_error("导出交易记录失败: #{e.message}", :internal_server_error)
          end
        end

        private

        def conditional_authenticate!
          user_filter = params[:user_filter]
          # 只有涉及用户个人数据的筛选才需要认证
          if ['my_trades', 'my_buys', 'my_sells'].include?(user_filter)
            authenticate_request!
          end
          # 否则不需要认证，允许公开访问
        end

        def build_base_query(market_id, order_type, user_filter, start_date, end_date)
          # 基础查询：只针对 order_fills，避免默认 includes
          query = ::Trading::OrderFill.all

          # 市场筛选
          if market_id.present?
            # 直接使用传入的market_id，不进行类型转换
            query = query.where(market_id: market_id)
          end

          # 用户筛选 - 使用新的地址字段（仅在有认证用户时应用）
          if current_user.present?
            current_address = current_user.address
            case user_filter
            when 'my_trades'
              # 我的所有交易（买入和卖出）
              query = query.where(
                "trading_order_fills.buyer_address = ? OR trading_order_fills.seller_address = ?",
                current_address, current_address
              )
            when 'my_buys'
              # 我的买入交易
              query = query.where("trading_order_fills.buyer_address = ?", current_address)
            when 'my_sells'
              # 我的卖出交易
              query = query.where("trading_order_fills.seller_address = ?", current_address)
            end
          end

          # 订单类型筛选
          if order_type.present? && order_type != 'all'
            case order_type
            when 'List', 'Offer'
              query = query.joins(:order)
                           .where("trading_orders.order_direction = ?", order_type)
            end
          end

          # 日期范围筛选
          if start_date.present?
            begin
              start_time = Time.at(start_date.to_i)
              query = query.where("trading_order_fills.created_at >= ?", start_time)
            rescue => e
              Rails.logger.warn "无效的开始日期: #{start_date}"
            end
          end

          if end_date.present?
            begin
              end_time = Time.at(end_date.to_i)
              query = query.where("trading_order_fills.created_at <= ?", end_time)
            rescue => e
              Rails.logger.warn "无效的结束日期: #{end_date}"
            end
          end

          query
        end

        def format_trade_data(trades, orders_by_id: nil, order_items_by_id: nil)
          trades.map do |trade|
            # 使用预加载数据（避免 N+1），缺省回退到关联
            order = orders_by_id ? orders_by_id[trade.order_id] : trade.order
            order_item = order_items_by_id ? order_items_by_id[trade.order_item_id] : trade.order_item

            # 获取订单类型
            order_direction = order&.order_direction || 'List'

            # 直接使用新的地址字段，这些字段由事件处理时正确设置
            buyer_address = trade.buyer_address
            seller_address = trade.seller_address

            # 根据订单方向获取正确的 item_id
            item_id = case order_direction
            when 'List'
              # List订单：offerer提供的是NFT，所以取offer_item_id
              order&.offer_item_id
            when 'Offer'
              # Offer订单：offerer想要的是NFT，所以取consideration_item_id
              order&.consideration_item_id
            else
              order&.offer_item_id # 默认值
            end

            # 计算价格（从price_distribution获取）
            price_in_wei = calculate_trade_price(trade)
            total_value_in_wei = (price_in_wei.to_d * trade.filled_amount.to_d).to_i

            {
              trade_hash: trade.transaction_hash,
              market_id: trade.market_id,
              order_type: order_direction, # 使用order_direction替代trade_type
              item_id: item_id, # 根据订单方向正确返回item_id
              token_id: order_item&.token_id,
              token_address: order_item&.token_address,
              amount: trade.filled_amount.to_f,
              price: price_in_wei.to_s,
              total_value: total_value_in_wei.to_s,
              timestamp: trade.created_at.to_i,
              block_timestamp: trade.block_timestamp,
              seller_address: seller_address,
              buyer_address: buyer_address,
              status: 'completed'
            }
          end
        end

        def format_trade_detail(trade)
          order = trade.order
          order_item = trade.order_item

          # 基础交易信息
          base_info = format_trade_data([trade]).first

          # 详细信息
          detail_info = {
            order_hash: order&.order_hash,
            buyer_order_hash: nil, # 暂时设为nil
            price_distribution: trade.price_distribution,
            log_index: trade.log_index,
            block_timestamp: trade.block_timestamp,
            marketplace: 'PuzzlEX', # 固定值
            royalty_info: extract_royalty_info(trade),
            item_details: {
              collection_address: order_item&.token_address,
              token_id: order_item&.token_id,
              role: order_item&.role,
              start_amount: order_item&.start_amount,
              end_amount: order_item&.end_amount
            }
          }

          base_info.merge(detail_info)
        end

        def format_export_data(trades, orders_by_id: nil, order_items_by_id: nil)
          trades.map do |trade|
            trade_data = format_trade_data([trade], orders_by_id: orders_by_id, order_items_by_id: order_items_by_id).first

            # 添加导出专用格式
            trade_data.merge({
              date: Time.at(trade_data[:timestamp]).strftime("%Y-%m-%d %H:%M:%S"),
              trade_type_text: {
                'buy' => '买入',
                'sell' => '卖出',
                'other' => '其他'
              }[trade_data[:trade_type]] || trade_data[:trade_type]
            })
          end
        end

        def calculate_statistics(query, user_filter)
          # 基础统计
          total_trades = query.count
          total_volume = query.sum(:filled_amount).to_f

          # 总交易额计算
          total_value = query.sum do |trade|
            calculate_trade_price(trade) * trade.filled_amount
          end

          # 按类型统计（仅针对用户相关的交易）
          buy_stats = { count: 0, volume: 0.0, value: 0.0 }
          sell_stats = { count: 0, volume: 0.0, value: 0.0 }

          if ['my_trades', 'my_buys', 'my_sells'].include?(user_filter) && current_user.present?
            current_address = current_user.address
            query.each do |trade|
              price = calculate_trade_price(trade)
              volume = trade.filled_amount.to_f
              value = price * volume

              # 使用新的地址字段判断买卖方
              is_buyer = trade.buyer_address == current_address
              is_seller = trade.seller_address == current_address

              if is_buyer
                buy_stats[:count] += 1
                buy_stats[:volume] += volume
                buy_stats[:value] += value
              elsif is_seller
                sell_stats[:count] += 1
                sell_stats[:volume] += volume
                sell_stats[:value] += value
              end
            end
          end

          # 最近交易活动（最近7天）
          recent_query = query.where("trading_order_fills.created_at >= ?", 7.days.ago)
          recent_trades = recent_query.count
          recent_volume = recent_query.sum(:filled_amount).to_f

          {
            total_trades: total_trades,
            total_volume: total_volume.round(4),
            total_value: total_value.round(4),
            buy_trades: buy_stats,
            sell_trades: sell_stats,
            recent_activity: {
              trades_7d: recent_trades,
              volume_7d: recent_volume.round(4)
            },
            period: {
              start_date: query.minimum(:created_at)&.to_i,
              end_date: query.maximum(:created_at)&.to_i
            }
          }
        end

        def calculate_trade_price(trade)
          MarketData::PriceCalculator.calculate_price_from_fill(trade)
        end

        def preload_trade_associations(trades)
          return [{}, {}] if trades.empty?

          order_ids = trades.map(&:order_id).compact.uniq
          order_item_ids = trades.map(&:order_item_id).compact.uniq

          orders_by_id = if order_ids.any?
                           ::Trading::Order
                             .where(id: order_ids)
                             .select(:id, :order_direction, :offer_item_id, :consideration_item_id)
                             .index_by(&:id)
                         else
                           {}
                         end

          order_items_by_id = if order_item_ids.any?
                                ::Trading::OrderItem
                                  .where(id: order_item_ids)
                                  .select(:id, :token_id, :token_address, :role, :start_amount, :end_amount)
                                  .index_by(&:id)
                              else
                                {}
                              end

          [orders_by_id, order_items_by_id]
        end

        def get_buyer_address(trade)
          # 优先使用新的buyer_address字段
          return trade.buyer_address if trade.buyer_address.present?

          # 如果没有buyer_address，记录警告并返回nil
          Rails.logger.warn "No buyer_address found for trade #{trade.id}, this should not happen with new implementation"
          nil
        end

        def extract_royalty_info(trade)
          return {} unless trade.price_distribution.is_a?(Array)

          royalty_info = []
          order = trade.order

          trade.price_distribution.each do |dist|
            next unless dist["recipients"].is_a?(Array)

            dist["recipients"].each do |recipient|
              # 如果不是主要交易方，可能是版税
              unless [order&.offerer, get_buyer_address(trade)].include?(recipient["address"])
                royalty_info << {
                  address: recipient["address"],
                  amount: recipient["amount"].to_f,
                  token_address: dist["token_address"]
                }
              end
            end
          end

          royalty_info
        end
      end
    end
  end
end
