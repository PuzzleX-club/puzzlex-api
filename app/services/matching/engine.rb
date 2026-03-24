class Matching::Engine
  attr_reader :market_id, :logger

  # ✅ 安全常量定义
  DP_SCALE_FACTOR = 1                # NFT整数交易不需要缩放
  MAX_DP_ARRAY_SIZE = 10000          # DP算法最大数组大小限制
  MAX_RECURSION_DEPTH = 100          # 递归算法最大深度限制
  def initialize(market_id, trigger_source = 'manual')
    @market_id = market_id
    @redis_key = "order_matching:#{@market_id}"
    @logger = Matching::State::Logger.new(market_id, trigger_source)
    @validator = Matching::State::OrderStatusValidator.new
    @current_bid_order = nil  # 当前处理的买单
  end

  # 新增：判断是否为Collection订单（Merkle根哈希）
  def is_collection_order?(identifier)
    collection_support.is_collection_order?(identifier)
  end
  
  # 获取当前处理的买单订单对象
  def get_current_bid_order(combination)
    return @current_bid_order if @current_bid_order
    
    # 如果combination中有bid_hash，查询订单
    if combination[:bid_hash]
      @current_bid_order = Trading::Order.find_by(order_hash: combination[:bid_hash])
    end
    @current_bid_order
  end
  
  # 判断是否应该使用贪心算法
  def should_use_greedy_algorithm(bid_order, target_qty, available_asks)
    combination_selector.should_use_greedy_algorithm(bid_order, target_qty, available_asks)
  end
  
  # 贪心算法实现：尽可能多地匹配订单
  def find_optimal_combination_greedy(target_qty, asks)
    combination_selector.find_optimal_combination_greedy(target_qty, asks)
  end

  # ✅ 优化：验证token_id是否在指定Merkle树中（支持安全缓存）
  def token_in_merkle_tree?(token_id, merkle_root)
    collection_support.token_in_merkle_tree?(token_id, merkle_root)
  end

  # ✅ 新增：使用已获取的root_record验证token_id是否在Merkle树中
  def verify_token_in_merkle_with_snapshot(token_id, root_record)
    collection_support.verify_token_in_merkle_with_snapshot(token_id, root_record)
  end

  # ✅ 新增：计算安全的缓存过期时间
  def calculate_safe_cache_expiry(root_record, verification_result)
    collection_support.calculate_safe_cache_expiry(root_record, verification_result)
  end
  
  # 生成Collection订单的criteriaResolver
  def generate_criteria_resolver_for_order(order_index, ask_order, merkle_root)
    collection_support.generate_criteria_resolver_for_order(order_index, ask_order, merkle_root)
  end
  
  # 获取token的Merkle proof
  def get_merkle_proof_for_token(root_record, token_id)
    collection_support.get_merkle_proof_for_token(root_record, token_id)
  end

  # ✅ 新增：清理指定Merkle根的所有相关缓存
  def clear_merkle_cache_for_root(merkle_root)
    collection_support.clear_merkle_cache_for_root(merkle_root)
  end

  # ✅ 新增：批量预热Merkle验证缓存
  def preload_merkle_cache(bids, asks)
    collection_support.preload_merkle_cache(bids, asks)
  end

  # 新增：改进的订单兼容性分组方法
  def group_orders_by_compatibility(bids, asks)
    collection_support.group_orders_by_compatibility(bids, asks)
  end

  # 查找潜在匹配的订单
  def find_match_orders
    order_discovery.find_match_orders
  end

  # 根据匹配的订单生成 fulfillment 数据
  def generate_fulfillment(match_orders)
    fulfillment_builder.generate(match_orders, mxn_enabled: mxn_enabled?)
  end

  def generate_fulfillment_v2(match_orders)
    fulfillment_builder.generate_v2(match_orders)
  end

  # 主入口函数，调用执行的步骤
  def perform
    begin
      Rails.logger.info "[MatchEngine] ===== 开始撮合 ====="
      Rails.logger.info "[MatchEngine] 市场ID: #{@market_id}"
      Rails.logger.info "[MatchEngine] 触发源: #{@trigger_source}"
      
      # 检查订单数量
      order_count = Trading::Order.where(
        market_id: @market_id,
        onchain_status: %w[pending validated partially_filled],
        offchain_status: 'active'
      ).count
      Rails.logger.info "[MatchEngine] 待撮合订单数: #{order_count}"
      
      match_orders = find_match_orders
      Rails.logger.info "[MatchEngine] find_match_orders 完成，找到 #{match_orders&.size || 0} 个匹配"
      
      if match_orders.blank?
        Rails.logger.info "[MatchEngine] 没有找到匹配的订单"
        # 没有订单，将redis置为waiting
        set_redis_status_to_waiting
        @logger.log_session_cancelled('no_match_orders') if @logger
        return {
          success: false,
          message: "无匹配订单",
          matches: 0,
          matched_count: 0,
          matched_orders: []
        }
      else
        Rails.logger.info "[MatchEngine] 开始生成履行数据..."
        match_data = generate_fulfillment(match_orders)
        
        # 🆕 将match_orders传递给match_data，供部分撮合参数生成使用
        match_data[:match_orders] = match_orders
        
        Rails.logger.info "[MatchEngine] 更新订单状态..."
        # ✅ 新增：撮合成功后更新订单状态
        @validator.update_orders_after_matching(match_orders)
        
        Rails.logger.info "[MatchEngine] 存储到Redis..."
        # 有订单，将订单数据存储到redis中
        store_match_data_in_redis(match_data)
        
        # ✅ 记录队列操作：订单退出主队列，成功撮合
        order_hashes = match_data[:orders_hash] || []
        @logger.log_queue_exit(order_hashes, 'matched', 'redis_storage')
        @logger.log_session_success(
          description: 'matched',
          matched_groups_count: match_orders.size,
          matched_orders_count: order_hashes.size,
          matching_details: {
            market_id: @market_id,
            orders_count: order_hashes.size
          }
        ) if @logger
        
        Rails.logger.info "[MatchEngine] ===== 撮合成功 ====="
        Rails.logger.info "[MatchEngine] 撮合完成并已更新订单状态，找到 #{match_orders.size} 个匹配"
        return {
          success: true,
          matches: match_orders.size,
          matched_count: match_orders.size,
          matched_orders: match_orders,
          orders_count: order_hashes.size
        }
      end
    rescue => e
      Rails.logger.error "[MatchEngine] ===== 撮合失败 ====="
      Rails.logger.error "[MatchEngine] 错误: #{e.class.name}: #{e.message}"
      Rails.logger.error "[MatchEngine] 位置: #{e.backtrace.first}"
      
      # ✅ 改进：撮合失败时使用双队列架构处理
      begin
        # 从匹配的订单中提取所有order_hash
        order_hashes = []
        if match_orders&.any?
          match_orders.each do |match|
            if match['side'] == 'Offer'
              order_hashes << match['bid'][2]  # 买单hash
              order_hashes.concat(match['ask'][:current_orders])  # 卖单hashes
            end
          end
          
          if order_hashes.any?
            handle_match_failure(order_hashes, e)
          end
        end
      rescue => restore_error
        Rails.logger.error "[MatchEngine] 处理失败恢复时出错: #{restore_error.message}"
      end
      
      # ✅ 记录会话失败
      @logger.log_session_failure(e) if @logger
      
      # 重新抛出原始异常
      raise e
    end
  end

  private

  # 🚀 新的动态规划算法实现

  def find_optimal_combination_dp(target_qty, asks)
    combination_selector.find_optimal_combination_dp(
      target_qty,
      asks,
      legacy_fallback: method(:find_best_ask_combination_legacy),
      algorithm_fallback_logger: method(:log_algorithm_fallback)
    )
  end

  # 🆕 优化的主要匹配入口，使用动态规划
  def find_best_ask_combination(bids, asks, start_idx = 0, current_combination = { current_qty: 0, match_completed: false, remaining_qty: 0, current_orders: [] })
    combination_selector.find_best_ask_combination(
      bids,
      asks,
      start_idx: start_idx,
      current_combination: current_combination,
      dp_solver: method(:find_optimal_combination_dp)
    )
  end

  # 📦 保留原有递归算法作为备份，添加安全优化
  def find_best_ask_combination_legacy(target_qty, asks, start_idx = 0, current_orders = [], depth = 0)
    combination_selector.find_best_ask_combination_legacy(
      target_qty,
      asks,
      start_idx: start_idx,
      current_orders: current_orders,
      depth: depth
    )
  end

  # 匹配买单和卖单的订单
  def match_orders(bids, asks, max_rounds = 10)
    round_matcher.match_orders(bids, asks, max_rounds: max_rounds)
  end

  # 全局 MxN 精确撮合：
  # - 目标：寻找可执行的完整子组合（complete executable subset）
  # - 兼容 1vN/1v1：当只有一个 bid 时自然退化
  def match_orders_mxn_global(bids, asks)
    mxn_matcher.match_orders(bids, asks)
  end

  def mxn_search_options
    config = match_engine_config

    {
      max_layers: config.max_layers || 5,
      max_targets: config.max_targets || 8,
      flow_budget: config.flow_budget || 20,
      round_timeout_ms: config.round_timeout_ms || 500,
      max_bitset_size: config.max_bitset_size || MAX_DP_ARRAY_SIZE
    }
  end

  def mxn_runtime_options
    config = match_engine_config

    {
      window_size: config.window_size || 150,
      max_rounds: config.max_rounds || 10,
      total_timeout_ms: config.total_timeout_ms || 3000
    }
  end

  def store_match_data_in_redis(match_data)
    result_store.store_match_data_in_redis(match_data)
  end
  
  # 降级处理：当队列操作失败时，回退到Hash存储
  def fallback_to_hash_storage(match_data)
    result_store.fallback_to_hash_storage(match_data)
  end

  def set_redis_status_to_waiting
    result_store.set_redis_status_to_waiting
  end
  
  private
  
  # 处理撮合失败的订单（双队列架构）
  def handle_match_failure(order_hashes, error)
    result_store.handle_match_failure(order_hashes, error)
  end
  
  # 数据清洗方法
  def sanitize_orders(orders, type)
    return [] if orders.nil? || orders.empty?
    
    require_relative '../../errors/matching_errors'
    
    sanitized = []
    orders.each_with_index do |order, index|
      begin
        # 确保是数组格式
        unless order.is_a?(Array) && order.size >= 3
          raise ArgumentError, "订单格式错误：需要[price, qty, hash, ...]"
        end
        
        # 类型转换和验证
        price = to_numeric(order[0], "#{type}[#{index}].price")
        qty = to_numeric(order[1], "#{type}[#{index}].qty")
        hash = order[2].to_s
        
        # 验证数值合理性
        if qty <= 0
          @logger.add_warning("跳过无效订单：数量<=0", {
            type: type,
            index: index,
            qty: qty,
            hash: hash
          }) if @logger
          next
        end
        
        # 保留所有原始字段，特别是时间戳（索引4）
        sanitized << [price, qty, hash, order[3], order[4]]
        
      rescue => e
        if @logger
          @logger.log_error("订单数据清洗失败", {
            type: type,
            index: index,
            order: order.inspect,
            error: e.message
          })
        else
          Rails.logger.error "[MatchEngine] 订单数据清洗失败: #{e.message}"
        end
      end
    end
    
    sanitized
  end
  
  # 安全的类型转换
  def to_numeric(value, field_desc)
    case value
    when Numeric
      value.to_f
    when String
      # 尝试转换
      if value.match?(/^\d*\.?\d+$/)
        value.to_f
      else
        raise MatchingErrors::DataTypeError.new(
          field_desc,
          'Numeric',
          'String',
          value
        )
      end
    when nil
      raise MatchingErrors::ValidationError.new("#{field_desc} 不能为空")
    else
      raise MatchingErrors::DataTypeError.new(
        field_desc,
        'Numeric',
        value.class.name,
        value
      )
    end
  end
  
  # 错误日志记录
  def log_matching_error(error, bid_hash, bid_qty, asks)
    error_context = {
      bid_hash: bid_hash,
      bid_qty: bid_qty,
      asks_sample: asks.first(2).map(&:inspect)
    }
    
    case error
    when MatchingErrors::BaseError
      if @logger
        @logger.log_error(error.message, error_context.merge(error.to_log_hash))
      else
        Rails.logger.error "[MatchEngine] #{error.message}: #{error_context.inspect}"
      end
    when TypeError, ArgumentError
      # 转换为更友好的错误
      friendly_error = MatchingErrors::DataTypeError.new(
        'unknown',
        'unknown',
        'unknown',
        error.message
      )
      if @logger
        @logger.log_error(friendly_error.message, error_context.merge(friendly_error.to_log_hash))
      else
        Rails.logger.error "[MatchEngine] #{friendly_error.message}: #{error_context.inspect}"
      end
    else
      if @logger
        @logger.log_error("未知错误", error_context.merge({
          error_class: error.class.name,
          error_message: error.message,
          backtrace: error.backtrace.first(3)
        }))
      else
        Rails.logger.error "[MatchEngine] 未知错误: #{error.message}"
      end
    end
  end
  
  # 算法降级日志（内部方法，不依赖外部Logger）
  def log_algorithm_fallback(from_algorithm, to_algorithm, reason)
    Rails.logger.info "[ALGORITHM:#{@market_id}] 算法降级: #{from_algorithm} → #{to_algorithm}, 原因: #{reason}"
    
    # 可选：尝试记录到 Matching::State::Logger 的 queue_operations 中
    # 但不应该因为日志失败而影响主流程
    begin
      if @logger && @logger.instance_variable_defined?(:@queue_operations)
        operation = {
          timestamp: Time.current.iso8601,
          operation: 'algorithm_fallback',
          from_algorithm: from_algorithm,
          to_algorithm: to_algorithm,
          reason: reason
        }
        queue_operations = @logger.instance_variable_get(:@queue_operations)
        queue_operations << operation if queue_operations.is_a?(Array)
      end
    rescue => e
      # 忽略日志记录错误
      Rails.logger.debug "[ALGORITHM] 无法记录降级日志到queue_operations: #{e.message}"
    end
  end
  
  # 🆕 判断是否需要部分撮合
  def needs_partial_fill?(match_orders)
    partial_fill_builder.needs_partial_fill?(match_orders)
  end
  
  # 🆕 计算卖单总量
  def calculate_total_ask_qty(ask_order_hashes)
    partial_fill_builder.calculate_total_ask_qty(ask_order_hashes)
  end
  
  # 🆕 从订单中提取数量
  def extract_order_quantity(order)
    partial_fill_builder.extract_order_quantity(order)
  end
  
  # 🆕 生成部分撮合参数（基于增强的匹配数据）
  def generate_partial_fill_options(match_orders)
    partial_fill_builder.generate_partial_fill_options(match_orders)
  end

  # 构建卖单真实成交量拆分（按撮合顺序扣减）
  def build_ask_fill_breakdown(current_order_hashes, asks, total_filled_qty)
    partial_fill_builder.build_ask_fill_breakdown(current_order_hashes, asks, total_filled_qty)
  end

  def build_criteria_resolvers_from_graph(match_orders, graph, orders_by_hash)
    collection_support.build_criteria_resolvers_from_graph(match_orders, graph, orders_by_hash)
  end

  def collection_support
    @collection_support ||= Matching::Collection::OrderSupport.new
  end

  def result_store
    @result_store ||= Matching::State::ResultStore.new(
      market_id: @market_id,
      redis_key: @redis_key,
      logger: @logger,
      validator: @validator
    )
  end

  def partial_fill_builder
    @partial_fill_builder ||= Matching::Fulfillment::PartialFillBuilder.new(
      numeric_parser: method(:to_numeric)
    )
  end

  def combination_selector
    @combination_selector ||= Matching::Selection::CombinationSelector.new(
      scale_factor: DP_SCALE_FACTOR,
      max_dp_array_size: MAX_DP_ARRAY_SIZE,
      max_recursion_depth: MAX_RECURSION_DEPTH
    )
  end

  def mxn_matcher
    @mxn_matcher ||= Matching::Execution::MxnMatcher.new(
      numeric_parser: method(:to_numeric),
      search_options_provider: method(:mxn_search_options),
      runtime_options_provider: method(:mxn_runtime_options)
    )
  end

  def round_matcher
    @round_matcher ||= Matching::Execution::RoundMatcher.new(
      order_sanitizer: method(:sanitize_orders),
      numeric_parser: method(:to_numeric),
      matching_error_logger: method(:log_matching_error),
      combination_finder: method(:find_best_ask_combination),
      ask_fill_breakdown_builder: method(:build_ask_fill_breakdown),
      mxn_enabled: method(:mxn_enabled?),
      mxn_matcher: method(:match_orders_mxn_global),
      current_bid_loader: lambda { |bid_hash|
        @current_bid_order = Trading::Order.find_by(order_hash: bid_hash)
      }
    )
  end

  def order_discovery
    @order_discovery ||= Matching::Discovery::OrderDiscovery.new(
      market_id: @market_id,
      validator: @validator,
      collection_support: collection_support,
      waiting_handler: method(:set_redis_status_to_waiting),
      match_executor: method(:match_orders)
    )
  end

  def fulfillment_builder
    @fulfillment_builder ||= Matching::Fulfillment::Builder.new(
      market_id: @market_id,
      collection_support: collection_support
    )
  end

  def mxn_enabled?
    match_engine_config.mxn_enabled == true
  end

  def match_engine_config
    Rails.application.config.x.match_engine
  end

end
