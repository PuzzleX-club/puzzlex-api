# frozen_string_literal: true

class Matching::OverMatch::BalanceGateway
  def get_player_token_balance(player_address, token_id)
    begin
      Rails.logger.debug "[OverMatch] 查询玩家 #{player_address} 的Token ID #{token_id} 余额"

      rpc_service = Blockchain::RpcService.for_current_environment
      balance = rpc_service.get_nft_balance(player_address, token_id)

      Rails.logger.debug "[OverMatch] RPC查询结果 - Token ID #{token_id} 余额: #{balance}"
      { balance: balance, source: :rpc, error: nil }
    rescue RpcServiceError => e
      Rails.logger.warn "[OverMatch] RPC查询失败，尝试Indexer回退: #{e.message}"
      get_indexer_token_balance(player_address, token_id)
    rescue => e
      Rails.logger.error "[OverMatch] 获取Token余额失败: #{e.message}"
      Rails.logger.error e.backtrace.join("\n")
      { balance: nil, source: nil, error: :unknown }
    end
  end

  def get_indexer_token_balance(player_address, token_id)
    begin
      balance = ItemIndexer::InstanceBalance
        .where("player = ? AND instance = ?", player_address.to_s.downcase, token_id.to_s)
        .pick(:balance)

      balance = balance.to_i
      Rails.logger.info "[OverMatch] Indexer回退成功: player=#{player_address}, token_id=#{token_id}, balance=#{balance}"
      { balance: balance, source: :indexer, error: nil }
    rescue => e
      Rails.logger.error "[OverMatch] Indexer查询失败: #{e.message}"
      Rails.logger.error e.backtrace.join("\n")
      { balance: nil, source: :indexer, error: :indexer_failed }
    end
  end

  def get_player_token_approval(player_address, operator_address)
    begin
      Rails.logger.debug "[OverMatch] 查询玩家 #{player_address} 的ERC1155授权: operator=#{operator_address}"

      rpc_service = Blockchain::RpcService.for_current_environment
      nft_contract = Rails.application.config.x.blockchain.nft_contract_address
      approved = rpc_service.get_erc1155_approval(nft_contract, player_address, operator_address)

      Rails.logger.debug "[OverMatch] ERC1155授权结果: #{approved}"
      { approved: approved, error: nil }
    rescue RpcServiceError => e
      Rails.logger.warn "[OverMatch] 获取ERC1155授权失败: #{e.message}"
      { approved: nil, error: :rpc_failed }
    rescue => e
      Rails.logger.error "[OverMatch] 获取ERC1155授权失败: #{e.message}"
      Rails.logger.error e.backtrace.join("\n")
      { approved: nil, error: :unknown }
    end
  end

  def get_player_currency_balance(player_address, currency_address)
    begin
      Rails.logger.debug "[OverMatch] 查询玩家 #{player_address} 的货币 #{currency_address} 余额"

      rpc_service = Blockchain::RpcService.for_current_environment
      balance = rpc_service.get_balance_by_address(currency_address, player_address)

      Rails.logger.debug "[OverMatch] 找到货币 #{currency_address} 余额: #{balance}"
      { balance: balance, error: nil }
    rescue RpcServiceError => e
      Rails.logger.warn "[OverMatch] 获取货币余额失败: #{e.message}"
      { balance: nil, error: :rpc_failed }
    rescue => e
      Rails.logger.error "[OverMatch] 获取货币余额失败: #{e.message}"
      Rails.logger.error e.backtrace.join("\n")
      { balance: nil, error: :unknown }
    end
  end

  def get_player_currency_allowance(player_address, currency_address, spender_address)
    begin
      Rails.logger.debug "[OverMatch] 查询玩家 #{player_address} 的ERC20授权: token=#{currency_address}, spender=#{spender_address}"

      rpc_service = Blockchain::RpcService.for_current_environment
      allowance = rpc_service.get_erc20_allowance(currency_address, player_address, spender_address)

      Rails.logger.debug "[OverMatch] ERC20授权结果: #{allowance}"
      { allowance: allowance, error: nil }
    rescue RpcServiceError => e
      Rails.logger.warn "[OverMatch] 获取ERC20授权失败: #{e.message}"
      { allowance: nil, error: :rpc_failed }
    rescue => e
      Rails.logger.error "[OverMatch] 获取ERC20授权失败: #{e.message}"
      Rails.logger.error e.backtrace.join("\n")
      { allowance: nil, error: :unknown }
    end
  end

  def seaport_contract_address
    Rails.application.config.x.blockchain.seaport_contract_address
  end
end
