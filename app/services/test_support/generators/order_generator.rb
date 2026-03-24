# 测试订单数据生成器
# 基于真实Seaport协议和业务逻辑生成测试订单数据

module TestSupport
  module Generators
    class OrderGenerator
      attr_reader :logger
    
    def initialize(logger = Rails.logger)
      @logger = logger
    end
    
    # 基于黄金数据生成完整的订单生态系统
    def generate_order_ecosystem(auth_users, market_configs = nil)
      logger.info "📋 开始生成订单生态系统..."
      
      # 获取黄金数据
      golden_items = Item.where(classification: '装备').limit(10)
      golden_instances = Instance.joins("JOIN items_sync ON instance_sync.product_id = items_sync.product_id")
                                .where("items_sync.classification = '装备'")
                                .limit(20)
      
      logger.info "  📦 使用 #{golden_items.count} 个Item，#{golden_instances.count} 个Instance"
      
      # 生成不同类型的订单
      results = {
        sell_orders: [],
        buy_orders: [],
        collection_orders: [],
        specific_orders: [],
        total_orders: 0,
        matching_pairs: []
      }
      
      # 为每个认证用户生成订单
      auth_users.each_with_index do |user_auth, index|
        user_orders = generate_user_orders(user_auth, golden_items, golden_instances)
        
        results[:sell_orders].concat(user_orders[:sell_orders])
        results[:buy_orders].concat(user_orders[:buy_orders])
        results[:collection_orders].concat(user_orders[:collection_orders])
        results[:specific_orders].concat(user_orders[:specific_orders])
        
        logger.info "  👤 用户 #{index + 1}: 生成了 #{user_orders[:total]} 个订单"
      end
      
      results[:total_orders] = results[:sell_orders].count + results[:buy_orders].count
      
      # 寻找潜在的撮合配对
      results[:matching_pairs] = find_potential_matches(results[:sell_orders], results[:buy_orders])
      
      logger.info "✅ 订单生态系统生成完成:"
      logger.info "  - 卖单: #{results[:sell_orders].count}"
      logger.info "  - 买单: #{results[:buy_orders].count}"
      logger.info "  - 集合订单: #{results[:collection_orders].count}"
      logger.info "  - 特定订单: #{results[:specific_orders].count}"
      logger.info "  - 潜在撮合对: #{results[:matching_pairs].count}"
      
      results
    end
    
    # 为单个用户生成多样化的订单
    def generate_user_orders(user_auth, items, instances)
      user = user_auth[:user]
      jwt_token = user_auth[:jwt_token]
      
      logger.info "  🎯 为用户 #{user.address} 生成订单"
      
      orders = {
        sell_orders: [],
        buy_orders: [],
        collection_orders: [],
        specific_orders: [],
        total: 0
      }
      
      # 生成卖单（基于用户"拥有"的NFT）
      user_instances = instances.sample(rand(3..8))
      user_instances.each do |instance|
        sell_order = create_realistic_sell_order(user, instance, jwt_token)
        if sell_order
          orders[:sell_orders] << sell_order
          orders[:specific_orders] << sell_order
        end
      end
      
      # 生成买单（基于市场需求）
      target_items = items.sample(rand(2..5))
      target_items.each do |item|
        # 30%几率生成集合订单，70%几率生成特定订单
        if rand < 0.3
          buy_order = create_collection_buy_order(user, item, jwt_token)
          orders[:collection_orders] << buy_order if buy_order
        else
          # 为特定token生成买单
          target_instance = instances.where("product_id = ?", item.product_id).sample
          if target_instance
            buy_order = create_specific_buy_order(user, target_instance, jwt_token)
            orders[:specific_orders] << buy_order if buy_order
          end
        end
        
        orders[:buy_orders] << buy_order if buy_order
      end
      
      orders[:total] = orders[:sell_orders].count + orders[:buy_orders].count
      orders
    end
    
    private
    
    def create_realistic_sell_order(user, instance, jwt_token)
      # 基于市场数据计算合理价格
      base_price = calculate_market_price(instance)
      
      # 价格在基准价格的90%-120%之间波动
      price_multiplier = 0.9 + (rand * 0.3) # 0.9 到 1.2
      final_price = (base_price * price_multiplier).round(6)
      
      # 生成真实的Seaport签名订单
      signed_order = generate_real_seaport_order(
        user, 
        :sell, 
        {
          nft_contract: instance.token_address || get_runtime_nft_contract,
          token_id: extract_token_id(instance.instance_id),
          price: (final_price * 1e18).to_i.to_s, # 转换为wei
          payment_token: get_runtime_payment_token
        }
      )
      
      if signed_order
        # 调用真实的订单创建API
        create_order_via_api(user, {
          side: 2, # 卖单
          order_type: 2, # 特定订单
          price: final_price.to_s,
          amount: "1",
          token_id: extract_token_id(instance.instance_id),
          collection_address: instance.token_address,
          seaport_order: signed_order
        }, jwt_token)
      else
        logger.error "❌ 无法生成Seaport签名订单"
        nil
      end
    end
    
    def create_specific_buy_order(user, instance, jwt_token)
      base_price = calculate_market_price(instance)
      
      # 买单价格通常比市场价低5%-15%
      price_multiplier = 0.85 + (rand * 0.10) # 0.85 到 0.95
      final_price = (base_price * price_multiplier).round(6)
      
      # 生成真实的Seaport签名订单
      signed_order = generate_real_seaport_order(
        user, 
        :buy, 
        {
          nft_contract: instance.token_address || get_runtime_nft_contract,
          token_id: extract_token_id(instance.instance_id),
          price: (final_price * 1e18).to_i.to_s, # 转换为wei
          payment_token: get_runtime_payment_token
        }
      )
      
      if signed_order
        create_order_via_api(user, {
          side: 1, # 买单
          order_type: 2, # 特定订单
          price: final_price.to_s,
          amount: "1",
          token_id: extract_token_id(instance.instance_id),
          collection_address: instance.token_address,
          seaport_order: signed_order
        }, jwt_token)
      else
        logger.error "❌ 无法生成Seaport签名订单"
        nil
      end
    end
    
    def create_collection_buy_order(user, item, jwt_token)
      # 集合订单的价格相对较低
      base_price = calculate_item_floor_price(item)
      
      # 集合订单价格比地板价低10%-25%
      price_multiplier = 0.75 + (rand * 0.15) # 0.75 到 0.90
      final_price = (base_price * price_multiplier).round(6)
      
      # 集合订单数量可以大于1
      quantity = [1, 1, 1, 2, 3].sample # 偏向于数量1
      
      # 生成真实的Seaport签名订单
      signed_order = generate_real_seaport_order(
        user, 
        :collection, 
        {
          nft_contract: get_item_contract_address(item),
          total_price: (final_price * quantity * 1e18).to_i.to_s, # 转换为wei
          quantity: quantity.to_s,
          item_id: get_item_id_from_item(item) # 传递item_id用于Merkle根生成
        }
      )
      
      if signed_order
        create_order_via_api(user, {
          side: 1, # 买单
          order_type: 1, # 集合订单
          price: final_price.to_s,
          amount: quantity.to_s,
          collection_address: get_item_contract_address(item),
          seaport_order: signed_order
        }, jwt_token)
      else
        logger.error "❌ 无法生成Seaport签名订单"
        nil
      end
    end
    
    def calculate_market_price(instance)
      # 根据item的稀有度和等级计算基础价格
      item = Item.find_by(product_id: instance.product_id)
      return 0.1 unless item # 默认价格
      
      base_price = 0.05 # 基础价格 0.05 ETH
      
      # 等级影响（等级越高价格越高）
      level_multiplier = 1 + (item.level.to_i - 1) * 0.1
      
      # 稀有度影响
      rarity_multiplier = case item.rarity&.downcase
      when 'common', '普通' then 1.0
      when 'uncommon', '不常见' then 1.5
      when 'rare', '稀有' then 2.5
      when 'epic', '史诗' then 4.0
      when 'legendary', '传说' then 8.0
      else 1.0
      end
      
      # 随机市场波动 ±20%
      market_volatility = 0.8 + (rand * 0.4) # 0.8 到 1.2
      
      final_price = base_price * level_multiplier * rarity_multiplier * market_volatility
      [final_price, 0.001].max # 最低价格 0.001 ETH
    end
    
    def calculate_item_floor_price(item)
      # 集合的地板价比平均价格低一些
      average_price = calculate_market_price_for_item(item)
      average_price * 0.7 # 地板价是平均价的70%
    end
    
    def calculate_market_price_for_item(item)
      # 为Item计算平均市场价格
      base_price = 0.05
      level_multiplier = 1 + (item.level.to_i - 1) * 0.1
      
      rarity_multiplier = case item.rarity&.downcase
      when 'common', '普通' then 1.0
      when 'uncommon', '不常见' then 1.5
      when 'rare', '稀有' then 2.5
      when 'epic', '史诗' then 4.0
      when 'legendary', '传说' then 8.0
      else 1.0
      end
      
      base_price * level_multiplier * rarity_multiplier
    end
    
    # 🆕 重构说明 (2025-07-14): 
    # 原有的Rails Seaport签名服务已移除，改为使用seaport.js Node.js脚本生成
    # 原因: seaport.js是官方库，保证签名格式100%准确
    # 新流程: Rails rake任务 → Node.js脚本 → JSON输出 → Rails数据库
    def generate_real_seaport_order(user, order_type, options = {})
      logger.warn "⚠️ generate_real_seaport_order已弃用"
      logger.warn "🔄 请使用seaport.js Node.js脚本生成真实签名"
      logger.warn "📍 位置: scripts/seaport/generate_order_signatures.js"
      nil
    end
    
    # 获取用户的测试私钥
    def get_user_private_key(user)
      # 从测试账户映射文件获取私钥
      accounts_file = Rails.root.join("../shared/test_network/hardhat_accounts.json")
      
      if File.exist?(accounts_file)
        accounts = JSON.parse(File.read(accounts_file))
        account_info = accounts.find { |acc| acc["address"].downcase == user.address.downcase }
        
        if account_info
          account_info["privateKey"]
        else
          logger.warn "⚠️ 无法找到用户 #{user.address} 的私钥"
          nil
        end
      else
        logger.warn "⚠️ 测试账户文件不存在: #{accounts_file}"
        nil
      end
    end
    
    def create_order_via_api(user, order_params, jwt_token)
      begin
        # 调用真实的订单创建API
        if defined?(Client::Market::Trading::OrdersController)
          controller = Client::Market::Trading::OrdersController.new
          
          # 模拟HTTP请求头
          controller.request = OpenStruct.new(
            headers: { 'Authorization' => "Bearer #{jwt_token}" }
          )
          
          result = controller.create(order_params)
          
          if result[:success]
            logger.info "    ✅ 订单创建成功: #{result[:order_hash]}"
            result[:order]
          else
            logger.warn "    ⚠️  订单创建失败: #{result[:message]}"
            nil
          end
        else
          # 如果没有真实API，创建模拟订单记录
          create_mock_order(user, order_params)
        end
      rescue => e
        logger.error "    ❌ 订单API调用失败: #{e.message}"
        create_mock_order(user, order_params)
      end
    end
    
    def create_mock_order(user, order_params)
      # 创建模拟订单记录
      order_hash = "0x#{SecureRandom.hex(32)}"
      
      mock_order = {
        order_hash: order_hash,
        offerer: user.address,
        side: order_params[:side],
        order_type: order_params[:order_type],
        price: order_params[:price],
        amount: order_params[:amount],
        token_id: order_params[:token_id],
        collection_address: order_params[:collection_address],
        onchain_status: 'validated',
        offchain_status: 'active',
        created_at: Time.current,
        seaport_order: order_params[:seaport_order]
      }
      
      # 如果有Trading::Order模型，保存到数据库
      if defined?(Trading::Order)
        Trading::Order.create!(mock_order.except(:seaport_order))
      else
        # 保存到缓存
        Rails.cache.write("mock_order:#{order_hash}", mock_order, expires_in: 1.day)
      end
      
      logger.info "    ✅ 模拟订单创建: #{order_hash}"
      mock_order
    end
    
    def find_potential_matches(sell_orders, buy_orders)
      matches = []
      
      sell_orders.each do |sell_order|
        buy_orders.each do |buy_order|
          if orders_can_match?(sell_order, buy_order)
            matches << {
              sell_order: sell_order,
              buy_order: buy_order,
              match_type: determine_match_type(sell_order, buy_order),
              price_difference: (sell_order[:price].to_f - buy_order[:price].to_f).abs
            }
          end
        end
      end
      
      # 按价格差异排序，优先匹配价格接近的订单
      matches.sort_by { |m| m[:price_difference] }.first(10)
    end
    
    def orders_can_match?(sell_order, buy_order)
      # 基础匹配条件
      return false if sell_order[:offerer] == buy_order[:offerer] # 不能自己和自己匹配
      return false if sell_order[:price].to_f > buy_order[:price].to_f # 价格不匹配
      
      # 具体订单匹配
      if sell_order[:order_type] == 2 && buy_order[:order_type] == 2
        return sell_order[:token_id] == buy_order[:token_id] &&
               sell_order[:collection_address] == buy_order[:collection_address]
      end
      
      # 集合订单匹配
      if buy_order[:order_type] == 1
        return sell_order[:collection_address] == buy_order[:collection_address]
      end
      
      false
    end
    
    def determine_match_type(sell_order, buy_order)
      if sell_order[:order_type] == 2 && buy_order[:order_type] == 2
        'specific_match'
      elsif buy_order[:order_type] == 1
        'collection_match'
      else
        'unknown_match'
      end
    end
    
    # 工具方法
    def extract_token_id(instance_id)
      # 从instance_id中提取token_id
      # 假设格式为: "item_id + suffix"
      instance_id.gsub(/^\d+/, '').to_i.to_s
    end
    
    def get_item_contract_address(item)
      # 获取item对应的合约地址，使用运行时配置
      instance = Instance.find_by(product_id: item.product_id)
      if instance&.token_address
        instance.token_address
      else
        # 从运行时配置获取默认NFT合约地址
        runtime_config = load_runtime_config
        runtime_config.dig("contracts", "TestERC1155") || "0x9fE46736679d2D9a65F0992F2272dE9f3c7fa6e0"
      end
    end

    def get_item_id_from_item(item)
      # 从Item对象获取itemId
      item.respond_to?(:itemId) ? item.itemId : item.id
    end

    def load_runtime_config
      # 加载运行时配置
      config_path = Rails.root.join("../shared/test_network/runtime_contracts.json")
      
      if File.exist?(config_path)
        JSON.parse(File.read(config_path))
      else
        logger.warn "⚠️ 运行时配置文件不存在: #{config_path}"
        {}
      end
    end

    def get_runtime_nft_contract
      # 从运行时配置获取NFT合约地址
      runtime_config = load_runtime_config
      nft_contract = runtime_config.dig("contracts", "TestERC1155")
      
      if nft_contract && nft_contract != "null"
        nft_contract
      else
        logger.warn "⚠️ 无法获取TestERC1155地址，使用默认值"
        "0x9fE46736679d2D9a65F0992F2272dE9f3c7fa6e0"
      end
    end

    def get_runtime_payment_token
      # 从运行时配置获取支付代币地址
      runtime_config = load_runtime_config
      payment_token = runtime_config.dig("contracts", "TestERC20")
      
      if payment_token && payment_token != "null"
        payment_token
      else
        logger.warn "⚠️ 无法获取TestERC20地址，使用默认值"
        "0xCf7Ed3AccA5a467e9e704C703E8D87F634fB0Fc9"
      end
    end
    
    
    # 清理方法
      def self.cleanup_test_orders
        Rails.logger.info "🧹 清理测试订单数据..."

        if defined?(Trading::Order)
          test_orders = Trading::Order.where("created_at > ?", 1.day.ago)
          deleted_count = test_orders.delete_all
          Rails.logger.info "  🗑️  清理了 #{deleted_count} 个测试订单"
        end

        # 清理缓存中的模拟订单
        Rails.cache.delete_matched("mock_order:*") if Rails.cache.respond_to?(:delete_matched)

        Rails.logger.info "✅ 测试订单数据清理完成"
      end
    end
  end
end
