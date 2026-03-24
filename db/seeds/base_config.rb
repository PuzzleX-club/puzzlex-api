# 基础配置种子数据
# 只包含系统运行必需的源头配置数据

return unless Rails.env.test?

puts "🔧 加载基础系统配置..."

# 系统基础配置
system_configs = [
  {
    key: 'platform_fee_bps',
    value: '150', # 1.5%
    description: '平台交易费率（基点）'
  },
  {
    key: 'royalty_fee_bps',
    value: '750', # 7.5%
    description: '版税费率（基点）'
  },
  {
    key: 'seaport_contract_address',
    value: ENV['TEST_SEAPORT_ADDRESS'] || '0x0000000000000068F116a894984e2DB1123eB395',
    description: 'Seaport协议合约地址'
  },
  {
    key: 'test_nft_contract_address',
    value: ENV['TEST_NFT_CONTRACT_ADDRESS'] || '0x9EF5B0Da15C84177164aD95F6C06FA787bDC5A4e',
    description: '测试NFT合约地址'
  },
  {
    key: 'max_orders_per_user',
    value: '100',
    description: '用户最大订单数量限制'
  }
]

# 创建系统配置（如果有SystemConfig模型）
if defined?(SystemConfig)
  system_configs.each do |config|
    SystemConfig.find_or_create_by!(key: config[:key]) do |sc|
      sc.value = config[:value]
      sc.description = config[:description]
      puts "  ✅ 系统配置: #{config[:key]} = #{config[:value]}"
    end
  end
else
  puts "  ⚠️  SystemConfig模型未定义，将配置存储在环境变量中"
  system_configs.each do |config|
    puts "  📋 配置: #{config[:key]} = #{config[:value]}"
  end
end

# 区块链网络配置
chain_configs = [
  {
    chain_id: 31338,
    name: 'Anvil Local',
    rpc_url: 'http://127.0.0.1:8546',
    is_testnet: true,
    block_explorer: nil
  },
  {
    chain_id: 1,
    name: 'Ethereum Mainnet',
    rpc_url: ENV['MAINNET_RPC_URL'],
    is_testnet: false,
    block_explorer: 'https://etherscan.io'
  },
  {
    chain_id: 11155111,
    name: 'Sepolia Testnet',
    rpc_url: ENV['SEPOLIA_RPC_URL'],
    is_testnet: true,
    block_explorer: 'https://sepolia.etherscan.io'
  }
]

# 创建区块链网络配置（如果有ChainConfig模型）
if defined?(ChainConfig)
  chain_configs.each do |config|
    ChainConfig.find_or_create_by!(chain_id: config[:chain_id]) do |cc|
      cc.assign_attributes(config)
      puts "  ✅ 网络配置: #{config[:name]} (#{config[:chain_id]})"
    end
  end
else
  puts "  📋 区块链网络配置:"
  chain_configs.each do |config|
    puts "    - #{config[:name]} (Chain ID: #{config[:chain_id]})"
  end
end

puts "✅ 基础系统配置加载完成"