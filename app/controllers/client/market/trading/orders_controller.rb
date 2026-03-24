module Client
  module Market
    module Trading
      class OrdersController < ::Client::ProtectedController
        include Client::RequestLocale

        before_action :require_admin_for_full_list, only: [:full_list]

        # POST /api/market/trading/orders
        def create
          # 步骤 1: 验证订单签名
          validate_result = Orders::OrderValidateService.new(
            current_user,
            order_create_params
          ).validate

          unless validate_result[:success]
            Rails.logger.warn "[OrdersController#create] 订单验证失败: #{validate_result[:errors].join(', ')}"
            render_error(
              validate_result[:errors].join(', '),
              :unprocessable_entity
            )
            return
          end

          # 步骤 2: 验证通过后创建订单
          result = Orders::OrderCreateService.new(
            current_user,
            order_create_params,
            current_chain_id
          ).call

          if result[:success]
            render_success(
              {
                order_hash: result[:order].order_hash,
                onchain_status: result[:order].onchain_status
              },
              I18n.t('api.order.create.success')
            )
          else
            render_error(
              result[:errors].join(', '),
              :unprocessable_entity
            )
          end
        rescue StandardError => e
          Rails.logger.error "[OrdersController#create] Error: #{e.message}"
          Rails.logger.error e.backtrace.join("\n") if Rails.env.development?

          render_error(I18n.t('api.order.create.error'), :internal_server_error)
        end

        # GET /api/market/trading/orders/:order_hash
        def show
          order = ::Trading::Order.find_by(order_hash: order_hash_param)

          if order.blank?
            render_error(I18n.t('api.order.not_found'), :not_found)
            return
          end

          render_success(
            order_response(order),
            I18n.t('api.order.show.success')
          )
        end

        # POST /api/market/trading/orders/:order_hash/update_status
        def update_status
          order = ::Trading::Order.find_by(order_hash: order_hash_param)

          if order.blank?
            render_error(I18n.t('api.order.not_found'), :not_found)
            return
          end

          if order_owner_address(order) != current_user&.address&.downcase
            render_error(I18n.t('api.order.update_status.not_owner'), :forbidden)
            return
          end

          if params[:offchain_status].blank?
            render_error(I18n.t('api.order.update_status.missing_status'), :bad_request)
            return
          end

          status = params[:offchain_status].to_sym

          unless ::Trading::Order.offchain_statuses.key?(status)
            render_error(I18n.t('api.order.update_status.invalid_status'), :bad_request)
            return
          end

          begin
            Orders::OrderStatusManager.new(order).set_offchain_status!(status.to_s)
          rescue ArgumentError => e
            render_error(e.message, :unprocessable_entity)
            return
          end

          if order.reload
            # 发送状态更新的通知
            OrderStatusUpdateJob.perform_later(order.id)

            render_success(
              order_response(order),
              I18n.t('api.order.update_status.success')
            )
          else
            render_error(
              order.errors.full_messages.join(', '),
              :unprocessable_entity
            )
          end
        end

        # GET /api/market/trading/orders/:order_hash/tooltip
        def tooltip
          order = ::Trading::Order.find_by(order_hash: order_hash_param)

          if order.blank?
            render_error(I18n.t('api.order.not_found'), :not_found)
            return
          end

          render_success(
            order_tooltip_response(order),
            I18n.t('api.order.show.success')
          )
        end

        # GET /api/market/trading/orders
        def list
          @orders = ::Trading::Order.where(market_id: market_id_from_params, onchain_status: :validated)
                                  .includes(:order_fills)
                                  .order(price: order_direction_from_params)
                                  .limit(params[:limit]&.to_i || 200)

          render_success(
            order_list_response(@orders),
            I18n.t('api.order.list.success')
          )
        end

        # GET /api/market/trading/orders/full_list
        def full_list
          # 如果有block_number参数，说明是旧版本API调用
          if params[:block_number].present?
            block_number = params[:block_number].to_i
            Rails.logger.warn "[OrdersController] ⚠️ 旧版本API调用，block_number参数已忽略: #{block_number}"

            # 兼容旧版本：忽略block_number，继续使用新逻辑
            # 也可以选择返回错误告知升级，但这里选择优雅降级
          end

          list_result = build_full_list_response(allow_user_param: true)

          render_success(
            {
              data: order_full_list_response(
                list_result[:orders],
                filled_amount_map: list_result[:filled_amount_map]
              ),
              meta: list_result[:meta]
            },
            I18n.t('api.order.list.success')
          )
        end

        # GET /api/market/trading/orders/active_list
        def active_list
          list_result = build_full_list_response(
            allow_user_param: false,
            allow_status_params: false,
            override_onchain_statuses: %w[pending validated partially_filled],
            override_offchain_statuses: %w[active matching]
          )

          render_success(
            {
              data: order_full_list_response(
                list_result[:orders],
                filled_amount_map: list_result[:filled_amount_map]
              ),
              meta: list_result[:meta]
            },
            I18n.t('api.order.list.success')
          )
        end

        # GET /api/market/trading/orders/user_list
        def user_list
          list_result = build_full_list_response(
            allow_user_param: false,
            user_address: current_user&.address,
            allow_status_params: true
          )

          render_success(
            {
              data: order_full_list_response(
                list_result[:orders],
                filled_amount_map: list_result[:filled_amount_map]
              ),
              meta: list_result[:meta]
            },
            I18n.t('api.order.list.success')
          )
        end

        # POST /api/market/trading/orders/batch_update_offchain_status
        def batch_update_offchain_status
          order_hashs = params[:order_hashs] || []
          offchain_status = params[:offchain_status]&.to_sym

          if order_hashs.blank?
            render_error(I18n.t('api.order.batch_update_status.missing_orders'), :bad_request)
            return
          end

          unless ::Trading::Order.offchain_statuses.key?(offchain_status)
            render_error(I18n.t('api.order.update_status.invalid_status'), :bad_request)
            return
          end

          if order_hashs.length > 100
            render_error(I18n.t('api.order.batch_update_status.too_many_orders'), :bad_request)
            return
          end

          # 将任务加入后台队列
          BatchUpdateOrderStatusJob.perform_later(
            order_hashs,
            offchain_status,
            current_chain_id
          )

          render_success({}, I18n.t('api.order.batch_update_status.success'))
        end

        # POST /api/market/trading/orders/batch_update_status
        def batch_update_status
          unless current_user&.admin?
            render_error(I18n.t('api.order.batch_update_status.admin_only'), :forbidden)
            return
          end

          order_hashs = params[:order_hashs] || []
          status = params[:status]&.to_sym

          if order_hashs.blank?
            render_error(I18n.t('api.order.batch_update_status.missing_orders'), :bad_request)
            return
          end

          unless ::Trading::Order.onchain_statuses.key?(status)
            render_error(I18n.t('api.order.update_status.invalid_status'), :bad_request)
            return
          end

          if order_hashs.length > 100
            render_error(I18n.t('api.order.batch_update_status.too_many_orders'), :bad_request)
            return
          end

          # 将任务加入后台队列
          AdminBatchUpdateOrderJob.perform_later(
            order_hashs,
            status,
            current_user.id
          )

          render_success({}, I18n.t('api.order.batch_update_status.success'))
        end

        # POST /api/market/trading/orders/check_balance_status
        def check_balance_status
          order_hashs = params[:order_hashs] || []

          if order_hashs.length > 100
            render_error(I18n.t('api.order.check_balance_status.too_many_orders'), :bad_request)
            return
          end

          player_addresses = if order_hashs.present?
            normalized_hashes = order_hashs.map { |order_hash| OrderUtils.to_order_hash(order_hash) }
            orders = ::Trading::Order.where(order_hash: normalized_hashes, offerer: current_user.address.to_s.downcase)
            if orders.empty?
              render_error(I18n.t('api.order.check_balance_status.missing_orders'), :bad_request)
              return
            end
            orders.pluck(:offerer).uniq
          else
            [current_user.address.to_s.downcase]
          end

          player_addresses.each do |player_address|
            Matching::OverMatch::Detection.check_player_orders(player_address)
          end

          render_success({}, I18n.t('api.order.check_balance_status.success'))
        end

        # GET /api/market/trading/orders/over_match_history
        def over_match_history
          order_hashs = params[:order_hashs] || []

          if order_hashs.blank?
            render_error(I18n.t('api.order.over_match_history.missing_orders'), :bad_request)
            return
          end

          if order_hashs.length > 100
            render_error(I18n.t('api.order.over_match_history.too_many_orders'), :bad_request)
            return
          end

          order_hashs = order_hashs.map do |order_hash|
            OrderUtils.to_order_hash(order_hash)
          end

          # 查询相关的OrderFill
          order_fills = OrderFill.joins(:order)
                                .where(trading_orders: { order_hash: order_hashs })

          render_success(
            order_fill_response(order_fills),
            I18n.t('api.order.over_match_history.success')
          )
        end

        # GET /api/market/trading/orders/balance_status_overview
        def balance_status_overview
          render_success(
            {},
            I18n.t('api.order.balance_status_overview.success')
          )
        end

        # POST /api/market/trading/orders/:order_hash/revalidate
        # 手动重试验证失败或超匹配的订单
        def revalidate
          order = ::Trading::Order.find_by(order_hash: order_hash_param)

          if order.blank?
            render_error(I18n.t('api.order.not_found'), :not_found)
            return
          end

          if current_user&.address.to_s.downcase != order.offerer.to_s.downcase
            render_error('仅订单创建者可重试', :forbidden)
            return
          end

          request_id = SecureRandom.uuid
          Jobs::Orders::RevalidationJob.perform_async(
            order.id,
            current_user.id,
            {
              request_id: request_id,
              actor_address: current_user&.address
            }
          )

          render json: {
            code: 202,
            message: '重试已提交，处理中',
            data: {
              order_hash: order.order_hash,
              request_id: request_id
            }
          }, status: :accepted
        rescue => e
          Rails.logger.error "[OrdersController#revalidate] 重试验证失败: #{e.message}"
          render_error('重试验证失败', :internal_server_error)
        end

        private

        def order_create_params
          # 兼容两种参数格式：
          # 1. Seaport 格式: { order: { order_hash, signature, parameters: {...} } }
          # 2. 旧格式: { order: { market_id, order_direction, ... } }
          if params[:order][:parameters].present?
            # Seaport 格式
            params.require(:order).permit(:order_hash, :signature, parameters: {})
          else
            # 旧格式
            params.require(:order).permit(
              :market_id,
              :order_direction,
              :price,
              :quantity,
              :expiry,
              :nonce,
              :salt,
              :signature,
              :order_type,
              :extra_data,
              :create_time,
              order_items: %i[item_id quantity]
            )
          end
        end

        def order_hash_param
          params[:order_hash] || params[:id]
        end

        def order_response(order)
          item_name_map = build_item_name_map([order])
          order_response_data(
            order,
            show_info: true,
            show_user_info: should_show_user_info?(order),
            item_name_map: item_name_map,
            include_order_params: true
          )
        end

        def order_list_response(orders)
          item_name_map = build_item_name_map(orders)
          orders.map do |order|
            order_response_data(order, item_name_map: item_name_map)
          end
        end

        def order_full_list_response(orders, filled_amount_map: nil)
          item_name_map = build_item_name_map(orders)
          orders.map do |order|
            order_response_data(
              order,
              item_name_map: item_name_map,
              filled_amount_map: filled_amount_map
            )
          end
        end

        def order_fill_response(order_fills)
          order_fills.map do |fill|
            {
              id: fill.id,
              order_hash: fill.order_hash,
              market_id: fill.market_id,
              price: fill.price,
              amount: fill.amount,
              fill_direction: fill.fill_direction,
              buyer_address: fill.buyer_address,
              seller_address: fill.seller_address,
              transaction_hash: fill.transaction_hash,
              created_at: fill.created_at
            }
          end
        end

        def order_tooltip_response(order)
          item_name_map = build_item_name_map([order])
          order_response_data(order, tooltip: true, item_name_map: item_name_map, include_order_params: true)
        end

        def market_id_from_params
          market_id = params[:market_id]

          return '0' if market_id.blank?

          market_id.to_s
        end

        def order_direction_from_params
          order_direction = params[:order_direction]

          return 'asc' if order_direction.blank?

          %w[asc desc].include?(order_direction.to_s) ? order_direction.to_s : 'asc'
        end

        def order_owner_address(order)
          order.offerer&.downcase
        end

        def order_user(order)
          return nil if order.offerer.blank?

          @order_user_cache ||= {}
          key = order.offerer.downcase
          @order_user_cache[key] ||= Accounts::User.find_by(address: key)
        end

        def should_show_user_info?(order)
          return false unless current_user

          owner_match = order_owner_address(order) == current_user.address&.downcase
          owner_match || current_user.admin?
        end

        def valid_block_number?(block_number)
          block_number >= 0 && block_number <= (2**64 - 1)
        end

        # 新方法：处理订单状态参数映射（前端 -> 数据库）
        def parse_onchain_statuses(status_param)
          return nil if status_param.blank?

          statuses = status_param.is_a?(Array) ? status_param : status_param.split(',')

          # 状态值映射：前端 -> 数据库
          status_mapping = {
            'pending' => 'pending',
            'validated' => 'validated',
            'partial' => 'partially_filled',  # 关键映射
            'filled' => 'filled',
            'cancelled' => 'cancelled'
          }

          statuses.map { |s| status_mapping[s.strip] || s.strip }.compact.uniq
        end

        def parse_status_params(status_param)
          return nil if status_param.blank?
          status_param.is_a?(Array) ? status_param : status_param.split(',')
        end

        def parse_offchain_status_params(status_param)
          return nil if status_param.blank?
          statuses = status_param.is_a?(Array) ? status_param : status_param.split(',')
          statuses.map(&:to_s)
        end

        def build_item_name_map(orders)
          locale = request_locale
          item_ids = orders.map do |order|
            order.order_direction == 'Offer' ? order.consideration_item_id : order.offer_item_id
          end.compact.map(&:to_i).reject(&:zero?).uniq
          return {} if item_ids.empty?

          items = CatalogData::Item.includes(:translations).where(item_id: item_ids)
          items.each_with_object({}) do |item, map|
            translation = item.translations.find { |t| t.locale == locale } ||
                          item.translations.find { |t| t.locale == 'zh-CN' } ||
                          item.translations.first
            map[item.item_id.to_i] = translation&.name
          end
        end

        def build_filled_amount_map(order_ids)
          return {} if order_ids.empty?

          ::Trading::OrderFill.where(order_id: order_ids).group(:order_id).sum(:filled_amount)
        end

        def order_response_data(order, options = {})
          # 使用动态插值计算价格（Wei）和数量
          current_price_wei = Orders::OrderHelper.calculate_price_in_progress_from_order(order)
          unfilled_amount = Orders::OrderHelper.calculate_unfill_amount_from_order(order)
          total_amount = Orders::OrderHelper.calculate_total_amount_from_order(order)

          # 使用聚合结果或预加载的 order_fills 数据计算已成交数量
          filled_amount_map = options[:filled_amount_map]
          filled_amount = if filled_amount_map
                            filled_amount_map[order.id].to_i
                          else
                            order.order_fills.sum(&:filled_amount)
                          end

          # 订单方向转换: 'Offer' (买单) -> 1, 'List' (卖单) -> 2
          order_direction_numeric = case order.order_direction
                                    when 'Offer' then 1
                                    when 'List' then 2
                                    else 0
                                    end


          # 获取物品信息（使用 request_locale 获取正确的语言）
          # 注意：对于买单(Offer)，物品在 consideration_item_id；对于卖单(List)，物品在 offer_item_id
          item_id_for_lookup = order.order_direction == 'Offer' ? order.consideration_item_id : order.offer_item_id
          item_name_map = options[:item_name_map] || {}
          item_name = item_name_map[item_id_for_lookup.to_i] || "物品 ##{item_id_for_lookup}"

          # 基础字段
          data = {
            order_hash: order.order_hash,
            market_id: order.market_id,
            order_direction: order_direction_numeric,
            # 价格保持 Wei 格式（字符串），前端使用 formatPrice() 转换
            price: current_price_wei&.to_s || order.start_price&.to_s,
            # amount: 已废弃，返回 -1 触发前端迁移，改用 total_amount 或 unfilled_amount
            amount: '-1',
            # filled_amount: 实际已成交数量（来自 OrderFill 历史成交表）
            filled_amount: filled_amount,
            # unfilled_amount: 实际未成交数量（通过插值计算）
            unfilled_amount: unfilled_amount&.to_s,
            # total_amount: 订单总数量（通过插值计算）
            total_amount: total_amount&.to_s,
            # total_filled: 合约中的分子（用于插值计算）
            total_filled: order.total_filled,
            # total_size: 合约中的分母（用于插值计算）
            total_size: order.total_size,
            onchain_status: order.onchain_status,
            offchain_status: order.offchain_status,
            order_type: order.order_type,
            # 物品信息
            item_id: item_id_for_lookup,
            item_name: item_name,
            # 创建者信息
            offerer: order.offerer,
            created_at: order.created_at,
            updated_at: order.updated_at
          }

          if options[:include_order_params]
            # Seaport 订单结构（Core SDK 需要）
            data[:order] = {
              parameters: order.parameters,
              signature: order.signature
            }
          end

          # 可选字段
          if options[:show_info]
            data[:offerer] = order.offerer
            # zone/nonce/salt 存在于 Seaport parameters 中，旧表结构无对应字段
            params_json = order.parameters || {}
            data[:zone] = params_json['zone']
            data[:nonce] = params_json['nonce']
            data[:salt] = params_json['salt']
            data[:signature] = order.signature
            data[:start_time] = order.start_time
            data[:end_time] = order.end_time
          end

          if options[:show_user_info]
            owner_user = order_user(order)
            data[:user] = {
              id: owner_user&.id,
              address: owner_user&.address || order.offerer,
              admin: owner_user&.admin? || false
            }
          end

          # OrderFill 信息
          if options[:show_trade_history] && order.order_fills.any?
            data[:order_fills] = order.order_fills.map do |fill|
              {
                id: fill.id,
                price: fill.price,
                amount: fill.amount,
                fill_direction: fill.fill_direction,
                transaction_hash: fill.transaction_hash,
                created_at: fill.created_at
              }
            end
          end

          data
        end
      end
    end
  end
end
        def require_admin_for_full_list
          return if current_user&.admin?

          render_error(I18n.t('api.order.batch_update_status.admin_only'), :forbidden)
        end

        def build_full_list_response(
          allow_user_param: true,
          allow_status_params: true,
          override_onchain_statuses: nil,
          override_offchain_statuses: nil,
          user_address: nil
        )
          market_id = params[:market_id]
          onchain_statuses = allow_status_params ? parse_onchain_statuses(params[:status]) : nil
          offchain_statuses = allow_status_params ? parse_offchain_status_params(params[:offchain_status]) : nil
          onchain_statuses = override_onchain_statuses if override_onchain_statuses.present?
          offchain_statuses = override_offchain_statuses if override_offchain_statuses.present?
          limit = [params[:limit].to_i, 100].min
          limit = 100 if limit <= 0
          last_id = params[:last_id]

          query = ::Trading::Order.all

          if allow_user_param && params[:user].present?
            user_address = if params[:user] == 'me'
                            current_user&.address
                          else
                            params[:user]
                          end
          end

          if user_address.present?
            query = query.where(offerer: user_address.to_s.downcase)
          end

          query = query.where(market_id: market_id) if market_id.present?

          filters = Catalog::ItemFilterParams.from_params(params)
          query = Catalog::ItemFilterService.apply_filters(query, **filters)

          query = query.where(onchain_status: onchain_statuses) if onchain_statuses.present?
          query = query.where(offchain_status: offchain_statuses) if offchain_statuses.present?

          query = query.where('id > ?', last_id) if last_id.present?

          order_ids = query.select(:id).distinct.order(id: :asc).limit(limit + 1).pluck(:id)
          has_more = order_ids.size > limit
          order_ids = order_ids.take(limit) if has_more

          orders = if order_ids.empty?
                     []
                   else
                     select_columns = %i[
                       id
                       order_hash
                       offerer
                       order_direction
                       start_price
                       end_price
                       start_time
                       end_time
                       consideration_start_amount
                       consideration_end_amount
                       offer_start_amount
                       offer_end_amount
                       total_filled
                       total_size
                       onchain_status
                       offchain_status
                       order_type
                       consideration_item_id
                       offer_item_id
                       market_id
                       created_at
                       updated_at
                     ]
                     ::Trading::Order.where(id: order_ids).select(select_columns).order(id: :asc).to_a
                   end

          filled_amount_map = build_filled_amount_map(order_ids)

          {
            orders: orders,
            filled_amount_map: filled_amount_map,
            meta: {
              limit: limit,
              last_id: orders.last&.id,
              has_more: has_more
            }
          }
        end
