# app/services/matching/state/queue_manager.rb
class Matching::State::QueueManager
  include Singleton

  # 队列键前缀
  MATCH_QUEUE_PREFIX = 'match_queue:'
  FAILED_QUEUE_PREFIX = 'match_failed_queue:'

  # 队列过期时间（防止队列无限增长）
  QUEUE_EXPIRE_TIME = 3600 # 1小时

  def initialize
    @logger = Rails.logger
  end

  # ==================== 主撮合队列操作 ====================

  # 入队撮合任务（生产者）
  def enqueue_match(market_id, match_data)
    validate_match_data!(match_data)

    queue_key = "#{MATCH_QUEUE_PREFIX}#{market_id}"
    json_data = prepare_match_data(match_data).to_json

    # LPUSH入队（从左边插入，FIFO）
    count = with_redis { |redis| redis.lpush(queue_key, json_data) }

    # 设置过期时间
    with_redis { |redis| redis.expire(queue_key, QUEUE_EXPIRE_TIME) }

    @logger.info "[QueueManager] 撮合任务入队 - 市场: #{market_id}, 队列深度: #{count}"

    # 记录入队操作到日志系统
    log_enqueue_operation(market_id, match_data)

    count
  rescue => e
    @logger.error "[QueueManager] 入队失败 - 市场: #{market_id}, 错误: #{e.message}"
    raise e if e.is_a?(ArgumentError)
    raise StandardError, "Failed to enqueue match: #{e.message}"
  end

  # 出队撮合任务（消费者）
  def dequeue_match(market_id, timeout: nil)
    queue_key = "#{MATCH_QUEUE_PREFIX}#{market_id}"

    # 使用RPOP从右边取出（FIFO）
    json_data = if timeout
      # 阻塞式出队（BRPOP）
      result = with_redis { |redis| redis.brpop(queue_key, timeout: timeout) }
      result&.last # brpop返回[key, value]
    else
      # 非阻塞式出队（RPOP）
      with_redis { |redis| redis.rpop(queue_key) }
    end

    return nil unless json_data

    match_data = JSON.parse(json_data, symbolize_names: true)
    return nil unless validate_dequeued_match_data!(market_id, match_data)

    @logger.debug "[QueueManager] 撮合任务出队 - 市场: #{market_id}"

    # 记录出队操作到日志系统
    log_dequeue_operation(market_id, match_data)

    match_data
  rescue JSON::ParserError => e
    @logger.error "[QueueManager] 解析队列数据失败 - 市场: #{market_id}, 错误: #{e.message}"
    nil
  rescue => e
    @logger.error "[QueueManager] 出队失败 - 市场: #{market_id}, 错误: #{e.message}"
    nil
  end

  # 批量出队（用于提高处理效率）
  def batch_dequeue_matches(market_id, batch_size: 10)
    queue_key = "#{MATCH_QUEUE_PREFIX}#{market_id}"
    matches = []

    batch_size.times do
      json_data = with_redis { |redis| redis.rpop(queue_key) }
      break unless json_data

      match_data = JSON.parse(json_data, symbolize_names: true)
      unless validate_dequeued_match_data!(market_id, match_data)
        @logger.error "[QueueManager] 跳过不合法撮合数据 - 市场: #{market_id}"
        next
      end
      matches << match_data
    rescue JSON::ParserError => e
      @logger.error "[QueueManager] 解析批量数据失败: #{e.message}"
      next
    end

    @logger.info "[QueueManager] 批量出队 - 市场: #{market_id}, 数量: #{matches.size}"
    matches
  end

  # ==================== 失败恢复队列操作 ====================

  # 入队失败任务
  def enqueue_recovery(market_id, recovery_data)
    queue_key = "#{FAILED_QUEUE_PREFIX}#{market_id}"

    # 添加失败时间戳和重试次数
    recovery_data[:failed_at] ||= Time.current.to_f
    recovery_data[:retry_count] ||= 0

    json_data = recovery_data.to_json

    count = with_redis { |redis| redis.lpush(queue_key, json_data) }
    with_redis { |redis| redis.expire(queue_key, QUEUE_EXPIRE_TIME) }

    @logger.warn "[QueueManager] 失败任务入队 - 市场: #{market_id}, 队列深度: #{count}"

    count
  rescue => e
    @logger.error "[QueueManager] 恢复队列入队失败 - 市场: #{market_id}, 错误: #{e.message}"
    0
  end

  # 出队失败任务（用于恢复处理）
  def dequeue_recovery(market_id)
    queue_key = "#{FAILED_QUEUE_PREFIX}#{market_id}"

    json_data = with_redis { |redis| redis.rpop(queue_key) }
    return nil unless json_data

    recovery_data = JSON.parse(json_data, symbolize_names: true)

    @logger.info "[QueueManager] 失败任务出队 - 市场: #{market_id}"

    recovery_data
  rescue JSON::ParserError => e
    @logger.error "[QueueManager] 解析恢复数据失败 - 市场: #{market_id}, 错误: #{e.message}"
    nil
  end

  # ==================== 队列监控和管理 ====================

  # 获取队列深度
  def queue_depth(market_id)
    queue_key = "#{MATCH_QUEUE_PREFIX}#{market_id}"
    with_redis { |redis| redis.llen(queue_key) }
  end

  # 获取失败队列深度
  def failed_queue_depth(market_id)
    queue_key = "#{FAILED_QUEUE_PREFIX}#{market_id}"
    with_redis { |redis| redis.llen(queue_key) }
  end

  # 获取所有市场的队列状态
  def all_queue_status
    status = {}

    # 获取所有撮合队列
    match_queues = with_redis { |redis| redis.keys("#{MATCH_QUEUE_PREFIX}*") }
    match_queues.each do |key|
      market_id = key.sub(MATCH_QUEUE_PREFIX, '')
      status[market_id] ||= {}
      status[market_id][:match_queue_depth] = with_redis { |redis| redis.llen(key) }
    end

    # 获取所有失败队列
    failed_queues = with_redis { |redis| redis.keys("#{FAILED_QUEUE_PREFIX}*") }
    failed_queues.each do |key|
      market_id = key.sub(FAILED_QUEUE_PREFIX, '')
      status[market_id] ||= {}
      status[market_id][:failed_queue_depth] = with_redis { |redis| redis.llen(key) }
    end

    status
  end

  # 查看队列内容（不移除）
  def peek_queue(market_id, count: 10)
    queue_key = "#{MATCH_QUEUE_PREFIX}#{market_id}"

    # LRANGE获取队列内容但不移除
    items = with_redis { |redis| redis.lrange(queue_key, 0, count - 1) }

    items.map do |json_data|
      JSON.parse(json_data, symbolize_names: true)
    rescue JSON::ParserError
      nil
    end.compact
  end

  # 清空队列（谨慎使用）
  def clear_queue(market_id)
    queue_key = "#{MATCH_QUEUE_PREFIX}#{market_id}"
    count = with_redis { |redis| redis.llen(queue_key) }
    with_redis { |redis| redis.del(queue_key) }

    @logger.warn "[QueueManager] 清空队列 - 市场: #{market_id}, 清除数量: #{count}"
    count
  end

  # 清空失败队列
  def clear_failed_queue(market_id)
    queue_key = "#{FAILED_QUEUE_PREFIX}#{market_id}"
    count = with_redis { |redis| redis.llen(queue_key) }
    with_redis { |redis| redis.del(queue_key) }

    @logger.warn "[QueueManager] 清空失败队列 - 市场: #{market_id}, 清除数量: #{count}"
    count
  end

  # ==================== 私有方法 ====================

private

  def with_redis(&block)
    ::Sidekiq.redis(&block)
  end

  # 验证撮合数据
  def validate_match_data!(match_data)
    raise ArgumentError, "Match data cannot be nil" if match_data.nil?
    raise ArgumentError, "Match data must have orders" unless match_data[:orders].present?
    raise ArgumentError, "Match data must have fulfillments" unless match_data[:fulfillments].present?

    version = (match_data[:match_data_version] || 'v1').to_s
    if version == 'v2'
      raise ArgumentError, "Match data v2 must have fills" unless match_data[:fills].present?
      if match_data[:partialFillOptions].present?
        raise ArgumentError, "Match data v2 does not allow partialFillOptions in strict full-fill mode"
      end
    end
  end

  # 准备撮合数据（添加元数据）
  def prepare_match_data(match_data)
    prepared_data = {
      queued_at: Time.current.to_f,
      match_data_version: match_data[:match_data_version] || 'v1',
      market_id: match_data[:market_id],
      orders: match_data[:orders],
      fulfillments: match_data[:fulfillments],
      orders_hash: match_data[:orders_hash] || extract_order_hashes(match_data[:orders]),
      metadata: {
        source: 'rails_matcher',
        version: '2.0',
        match_data_version: match_data[:match_data_version] || 'v1'
      }
    }

    if match_data[:fills].present?
      prepared_data[:fills] = match_data[:fills]
      @logger.info "[QueueManager] 📊 添加 fills 到队列数据: #{match_data[:fills].size} 个"
    end

    # 添加 criteriaResolvers 如果存在（用于Collection订单）
    if match_data[:criteriaResolvers].present?
      prepared_data[:criteriaResolvers] = match_data[:criteriaResolvers]
      @logger.info "[QueueManager] 📦 添加 criteriaResolvers 到队列数据: #{match_data[:criteriaResolvers].size} 个"
      @logger.info "[QueueManager] criteriaResolvers详情: #{match_data[:criteriaResolvers].to_json}"
    else
      @logger.debug "[QueueManager] 没有criteriaResolvers数据"
    end

    # 🆕 添加 partialFillOptions 如果存在（用于部分撮合）
    if match_data[:partialFillOptions].present?
      prepared_data[:partialFillOptions] = match_data[:partialFillOptions]
      @logger.info "[QueueManager] 📊 添加 partialFillOptions 到队列数据: #{match_data[:partialFillOptions].size} 个"
      @logger.info "[QueueManager] partialFillOptions详情: #{match_data[:partialFillOptions].to_json}"
    else
      @logger.debug "[QueueManager] 没有partialFillOptions数据"
    end

    prepared_data
  end

  def validate_dequeued_match_data!(market_id, match_data)
    version = (match_data[:match_data_version] || 'v1').to_s
    return true unless version == 'v2'

    unless match_data[:fills].present?
      @logger.error "[QueueManager] v2 出队数据缺少 fills - 市场: #{market_id}"
      return false
    end

    if match_data[:partialFillOptions].present?
      @logger.error "[QueueManager] v2 出队数据包含 partialFillOptions（严格模式禁止）- 市场: #{market_id}"
      return false
    end

    true
  end

  # 提取订单哈希
  def extract_order_hashes(orders)
    return [] unless orders.is_a?(Array)

    orders.map do |order|
      if order.is_a?(Hash)
        order[:order_hash] || order['order_hash']
      end
    end.compact
  end

  # 记录入队操作
  def log_enqueue_operation(market_id, match_data)
    return unless defined?(Matching::State::Logger)

    # 如果有活跃的日志记录器，记录入队操作
    if Thread.current[:matching_logger]
      logger = Thread.current[:matching_logger]
      order_hashes = extract_order_hashes(match_data[:orders])
      logger.log_queue_entry(order_hashes, 'discovered', 'queued')
    end
  rescue => e
    @logger.error "[QueueManager] 记录入队操作失败: #{e.message}"
  end

  # 记录出队操作
  def log_dequeue_operation(market_id, match_data)
    return unless defined?(Matching::State::Logger)

    if Thread.current[:matching_logger]
      logger = Thread.current[:matching_logger]
      order_hashes = match_data[:orders_hash] || []
      logger.log_queue_exit(order_hashes, 'processing', 'executor')
    end
  rescue => e
    @logger.error "[QueueManager] 记录出队操作失败: #{e.message}"
  end

  # ==================== 类方法（便捷访问） ====================

  class << self
    def enqueue_match(market_id, match_data)
      instance.enqueue_match(market_id, match_data)
    end

    def dequeue_match(market_id, timeout: nil)
      instance.dequeue_match(market_id, timeout: timeout)
    end

    def enqueue_recovery(market_id, recovery_data)
      instance.enqueue_recovery(market_id, recovery_data)
    end

    def dequeue_recovery(market_id)
      instance.dequeue_recovery(market_id)
    end

    def queue_depth(market_id)
      instance.queue_depth(market_id)
    end

    def failed_queue_depth(market_id)
      instance.failed_queue_depth(market_id)
    end

    def all_queue_status
      instance.all_queue_status
    end
  end
end
