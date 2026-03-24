module Client
  module Market
    module Assets
      class BalancesController < ::Client::ProtectedController
        include Client::IndexerAvailabilityHandling

        def index
          account = current_user&.address&.to_s&.downcase

          if account.blank?
            render_error("用户未认证", :unauthorized)
            return
          end

          # 1) 从NFT indexer获取所有存在余额的记录
          all_balances = ItemIndexer::InstanceBalance
                           .includes(instance_record: :item_record)
                           .where(player: account)
                           .where('balance > ?', 0)

          # 如果没有找到任何余额记录，返回空列表（这是正常情况）
          if all_balances.empty?
            Rails.logger.info("[BalancesController#index] 用户没有任何token余额")
            render json: { code: 200, data: [], msg: "查询成功" }
            return
          end

          # 2) 去重：按token_id取最新timestamp记录
          latest_balances = {}
          all_balances.each do |balance|
            token_id = balance.instance
            if !latest_balances[token_id] || balance.timestamp > latest_balances[token_id].timestamp
              latest_balances[token_id] = balance
            end
          end
          balances = latest_balances.values

          # 3) 收集所有 item 值
          item_values = balances.map { |b| b.instance_record&.item }.compact.uniq

          # 如果没有找到任何有效的 item 值，返回错误信息
          if item_values.empty?
            render_error("未找到相关物品记录", :not_found)
            return
          end

          items_map = Catalog::ItemNameLookup.call(item_values, locale: 'en')

          # 4) 按 item 值分组
          grouped = balances.group_by { |b| b.instance_record&.item }

          # 5) 针对每个 itemVal 分组，构建返回结构
          data_list = grouped.map do |itemVal, recs|
            # 5.1 计算该 itemVal 下的总余额
            total_balance = recs.sum(&:balance)

            # 5.2 生成 token_list，展示每条记录的 token_id + balance
            token_list = recs.map do |r|
              {
                token_id: r.instance,
                balance: r.balance.to_s,
              }
            end

            # 5.3 物品名称（暂时返回空字符串）
            item_name = items_map[itemVal] || ""

            {
              wallet_id: account,
              item_id: itemVal,
              balance: total_balance.to_s,
              token_list: token_list,
              frozen_amt: "0",
              status: 1,
              cur_name: item_name
            }
          end

          render json: {
            code: 200,
            data: data_list,
            msg: "成功获取余额列表"
          }
        end

        def get_balances
          # 获取请求参数
          allowed_params = params.permit(:market_id)
          market_id = allowed_params[:market_id]
          account = current_user&.address

          # 参数验证
          if market_id.blank? || account.blank?
            render_error("market_id 和 account 是必填参数", :bad_request)
            return
          end

          # 1) 从 market_id 中解析出 item_id, token_type
          item_id, token_type = parse_market_id(market_id)
          item_map = Catalog::ItemNameLookup.call([item_id], locale: 'en')

          if item_id.blank? || token_type.blank?
            render_error("market_id 格式不正确", :bad_request)
            return
          end

          # 2) 从NFT indexer获取玩家余额数据
          all_balances = ItemIndexer::InstanceBalance
                           .includes(instance_record: :item_record)
                           .joins(:instance_record)
                           .where(player: account.downcase)
                           .where('balance > ?', 0)
                           .where("#{ItemIndexer::Instance.table_name}.item = ?", item_id)

          # 3) 去重：按token_id取最新timestamp记录
          latest_balances = {}
          all_balances.each do |balance|
            token_id = balance.instance
            if !latest_balances[token_id] || balance.timestamp > latest_balances[token_id].timestamp
              latest_balances[token_id] = balance
            end
          end
          balances = latest_balances.values

          # 4) 计算总余额
          total_balance = balances.sum(&:balance)

          # 5) 生成 token_list，展示每条记录的 token_id + balance
          token_list = balances.map do |r|
            {
              token_id: r.instance,
              balance: r.balance.to_s,
            }
          end

          # 5) 物品名称
          item_name = item_map[item_id.to_i] || ""
          Rails.logger.info("item_name: #{item_name}")
          Rails.logger.info("item_map: #{item_map}")

          # todo：后端不便于获取，暂时使用上述自建索引器的余额，后续需要建立一个npm的微服务，提供余额查询服务
          # 6) 调用 RPC / contract 查询链上真实余额
          # 收集所有 token_ids（b.instance），有的项目 b.instance 就是 ERC1155 的 tokenId
          # token_ids = matching_records.map(&:instance).uniq
          # chain_balance_sum = 0
          # if token_ids.present?
          #   chain_balance_sum = query_chain_erc1155_balance_of_batch(account, token_ids)
          # end

          # todo:price通过另外的方法获取，提高性能
          # 7) 根据 token_type 判断 PriceToken
          #    "00" => NATIVE, "01" => USDC, "02" => DAI, etc.
          # user_price_balance = 0
          # if token_type == "00"
          #   user_price_balance = query_chain_native_balance(account)
          # else
          #   token_addr = PRICE_TOKEN_ADDRESS_MAP[token_type]&.account
          #   user_price_balance = query_chain_erc20_balance(token_addr, account)
          # end

          # 8) 组装返回数据
          data = {
            wallet_id: account,
            item_id: item_id,
            balance: total_balance.to_s,
            token_list: token_list,
            frozen_amt: "0",
            status: 1,
            cur_name: item_name,
          }

          render json: { code: 200, data: data, msg: "成功获取余额" }# 模拟获取余额的逻辑
        end

        # 获取当前用户在所有市场的余额
        def all_market_balances
          account = current_user&.address&.to_s&.downcase

          if account.blank?
            render_error("用户未认证", :unauthorized)
            return
          end

          # 输出简单日志，验证当前使用的账户地址
          Rails.logger.info("[all_market_balances] 查询账户地址: #{account}")

          # 从NFT indexer获取用户所有余额记录
          all_balances = ItemIndexer::InstanceBalance
                           .includes(instance_record: :item_record)
                           .where(player: account)
                           .where('balance > ?', 0)

          if all_balances.empty?
            Rails.logger.info("[all_market_balances] 用户没有任何token余额")
            render json: { code: 200, data: [], msg: "查询成功" }
            return
          end

          # 使用Ruby处理来获取每个token_id的最新记录
          # 按token_id分组，并只保留每组中时间戳最大的记录
          latest_balances = {}
          all_balances.each do |balance|
            token_id = balance.instance
            if !latest_balances[token_id] || balance.timestamp > latest_balances[token_id].timestamp
              latest_balances[token_id] = balance
            end
          end

          # 使用最新的余额记录
          balances = latest_balances.values

          # 按 item 分组
          grouped_by_item = balances.group_by { |b| b.instance_record&.item }

          item_ids = grouped_by_item.keys.compact.uniq
          item_names = Catalog::ItemNameLookup.call(item_ids, locale: 'en')

          # 构建返回数据 - 按物品汇总并返回物品信息
          result = []
          grouped_by_item.each do |item_id, records|
            next unless item_id.present?

            # 计算该 item 下的总余额
            total_balance = records.sum(&:balance)

            # 其他汇总数据
            total_minted = records.sum(&:minted_amount)
            total_transferred_in = records.sum(&:transferred_in_amount)
            total_transferred_out = records.sum(&:transferred_out_amount)
            total_burned = records.sum(&:burned_amount)

            # 生成 token_list，包含每个 token 的完整余额信息
            token_list = records.map do |r|
              {
                token_id: r.instance,
                balance: r.balance.to_s,
                minted_amount: r.minted_amount.to_s,
                transferred_in_amount: r.transferred_in_amount.to_s,
                transferred_out_amount: r.transferred_out_amount.to_s,
                burned_amount: r.burned_amount.to_s,
                timestamp: r.timestamp.to_s
              }
            end

            result << {
              item_id: item_id.to_s,
              item_name: item_names[item_id] || "",  # 暂时返回空字符串，待Item表迁移后补充
              balance: total_balance.to_s,
              minted_amount: total_minted.to_s,
              transferred_in_amount: total_transferred_in.to_s,
              transferred_out_amount: total_transferred_out.to_s,
              burned_amount: total_burned.to_s,
              token_list: token_list
            }
          end

          render json: {
            code: 200,
            data: result,
            msg: "成功获取所有物品余额"
          }
        end

        # 获取特定物品ID的余额（RESTful风格，基于NFT indexer）
        def show
          # 从路径参数获取物品ID
          item_id = params[:id]

          # 使用当前登录用户的地址
          account = current_user&.address&.to_s&.downcase

          # 参数验证
          if item_id.blank? || account.blank?
            render_error("item_id 和 account 是必填参数", :bad_request)
            return
          end

          # 输出简单日志，验证当前请求信息
          Rails.logger.info("[BalancesController#show] 查询账户 #{account} 的物品ID #{item_id} 余额（NFT indexer）")

          # 查询NFT indexer余额记录
          all_balances = ItemIndexer::InstanceBalance
                           .includes(instance_record: :item_record)
                           .joins(:instance_record)
                           .where(player: account)
                           .where('balance > ?', 0)
                           .where("#{ItemIndexer::Instance.table_name}.item = ?", item_id)

          if all_balances.empty?
            Rails.logger.info("[BalancesController#show] 用户没有物品ID #{item_id} 的token")
            # 返回成功但数据为空，这是正常情况（用户没有该物品的token）
            result = {
              item_id: item_id.to_s,
              item_name: "",
              balance: "0",
              minted_amount: "0",
              transferred_in_amount: "0",
              transferred_out_amount: "0",
              burned_amount: "0",
              token_list: []
            }
            render json: { code: 200, data: result, msg: "查询成功" }
            return
          end

          # 使用Ruby处理来获取每个token_id的最新记录
          # 按token_id分组，并只保留每组中时间戳最大的记录
          latest_balances = {}
          all_balances.each do |balance|
            token_id = balance.instance
            if !latest_balances[token_id] || balance.timestamp > latest_balances[token_id].timestamp
              latest_balances[token_id] = balance
            end
          end

          # 使用最新的余额记录
          balances = latest_balances.values

          item_names = Catalog::ItemNameLookup.call([item_id], locale: 'en')
          item_name = item_names[item_id.to_i] || ""

          # 计算该物品的总余额和其他汇总数据
          total_balance = balances.sum(&:balance)
          total_minted = balances.sum(&:minted_amount)
          total_transferred_in = balances.sum(&:transferred_in_amount)
          total_transferred_out = balances.sum(&:transferred_out_amount)
          total_burned = balances.sum(&:burned_amount)

          # 生成 token_list，包含每个 token 的完整余额信息
          token_list = balances.map do |r|
            {
              token_id: r.instance,
              balance: r.balance.to_s,
              minted_amount: r.minted_amount.to_s,
              transferred_in_amount: r.transferred_in_amount.to_s,
              transferred_out_amount: r.transferred_out_amount.to_s,
              burned_amount: r.burned_amount.to_s,
              timestamp: r.timestamp.to_s
            }
          end

          # 构建结果数据
          result = {
            item_id: item_id.to_s,
            item_name: item_name,
            balance: total_balance.to_s,
            minted_amount: total_minted.to_s,
            transferred_in_amount: total_transferred_in.to_s,
            transferred_out_amount: total_transferred_out.to_s,
            burned_amount: total_burned.to_s,
            token_list: token_list
          }

          Rails.logger.info("[BalancesController#show] 成功返回余额: total=#{total_balance}, tokens=#{token_list.length}")

          render json: {
            code: 200,
            data: result,
            msg: "成功获取物品余额"
          }
        end

        # @deprecated 请使用 GET /api/market/assets/balances/:id (show方法) 替代
        # 获取特定物品ID的余额（旧接口，已迁移到NFT indexer）
        def balance_by_item
          # 获取物品ID参数
          allowed_params = params.permit(:item_id)
          item_id = allowed_params[:item_id]

          # 使用当前登录用户的地址
          account = current_user&.address&.to_s&.downcase

          # 参数验证
          if item_id.blank? || account.blank?
            render_error("item_id 和 account 是必填参数", :bad_request)
            return
          end

          # 输出简单日志
          Rails.logger.info("[balance_by_item] 已废弃，请使用 GET /api/market/assets/balances/#{item_id}")
          Rails.logger.info("[balance_by_item] 查询账户 #{account} 的物品ID #{item_id} 余额")

          # 使用NFT indexer获取余额记录
          all_balances = ItemIndexer::InstanceBalance
                           .includes(instance_record: :item_record)
                           .joins(:instance_record)
                           .where(player: account)
                           .where('balance > ?', 0)
                           .where("#{ItemIndexer::Instance.table_name}.item = ?", item_id)

          if all_balances.empty?
            Rails.logger.info("[balance_by_item] 用户没有物品ID #{item_id} 的token")
            # 返回成功但数据为空
            result = {
              item_id: item_id.to_s,
              item_name: "",
              balance: "0",
              minted_amount: "0",
              transferred_in_amount: "0",
              transferred_out_amount: "0",
              burned_amount: "0",
              token_list: []
            }
            render json: { code: 200, data: result, msg: "查询成功" }
            return
          end

          # 使用Ruby处理来获取每个token_id的最新记录
          # 按token_id分组，并只保留每组中时间戳最大的记录
          latest_balances = {}
          all_balances.each do |balance|
            token_id = balance.instance
            if !latest_balances[token_id] || balance.timestamp > latest_balances[token_id].timestamp
              latest_balances[token_id] = balance
            end
          end

          # 使用最新的余额记录
          balances = latest_balances.values

          item_names_map = Catalog::ItemNameLookup.call([item_id], locale: 'en')
          item_name = item_names_map[item_id.to_i] || ""

          # 计算该物品的总余额和其他汇总数据
          total_balance = balances.sum(&:balance)
          total_minted = balances.sum(&:minted_amount)
          total_transferred_in = balances.sum(&:transferred_in_amount)
          total_transferred_out = balances.sum(&:transferred_out_amount)
          total_burned = balances.sum(&:burned_amount)

          # 生成 token_list，包含每个 token 的完整余额信息
          token_list = balances.map do |r|
            {
              token_id: r.instance,
              balance: r.balance.to_s,
              minted_amount: r.minted_amount.to_s,
              transferred_in_amount: r.transferred_in_amount.to_s,
              transferred_out_amount: r.transferred_out_amount.to_s,
              burned_amount: r.burned_amount.to_s,
              timestamp: r.timestamp.to_s
            }
          end

          # 构建结果数据
          result = {
            item_id: item_id.to_s,
            item_name: item_name,
            balance: total_balance.to_s,
            minted_amount: total_minted.to_s,
            transferred_in_amount: total_transferred_in.to_s,
            transferred_out_amount: total_transferred_out.to_s,
            burned_amount: total_burned.to_s,
            token_list: token_list
          }

          render json: {
            code: 200,
            data: result,
            msg: "成功获取物品余额"
          }
        end

        private

        # 从 market_id 中解析 item_id 和 token_type
        def parse_market_id(market_id)
          market_id = market_id.to_s
          # 假设 market_id 格式为 "<item_id><token_type>" (如 "100101")
          if market_id.length < 3
            return nil, nil # 确保 market_id 至少包含 item_id 和 token_type
          end

          item_id = market_id[0...-2] # 除去最后两位，剩下的是 item_id
          token_type = market_id[-2..] # 最后两位是 price_token_type

          [item_id, token_type]
        end

        # def query_chain_erc1155_balance_of_batch(wallet_address, token_ids)
        #   # 这里让 chunk_size = 20，表示一次最多处理20个 tokenId
        #   chunk_size = 20
        #   total_result = 0
        #
        #   # 分批遍历 token_ids
        #   token_ids.each_slice(chunk_size) do |slice|
        #     # slice是当前批次，如 [1001,1002,1003,...最多20个]
        #
        #     # 调用 'batch_balance_of_erc1155'，一次性查询 slice 里所有 TokenId
        #     # 返回形如 { tokenId1 => 10, tokenId2 => 5, ... }
        #     batch_map = rpc_client.batch_balance_of_erc1155(wallet_address, slice)
        #
        #     # 累加本批结果
        #     # 如果你需要分开保存或判断，也可保留
        #     total_result += batch_map.values.sum
        #   end
        #
        #   total_result
        # end
      end
    end
  end
end
