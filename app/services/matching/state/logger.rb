require 'ostruct'

class Matching::State::Logger
  attr_reader :log_entry, :session_id, :market_id, :start_time

  def initialize(market_id, trigger_source = 'unknown')
    @market_id = market_id
    @session_id = SecureRandom.uuid
    @start_time = Time.current
    @trigger_source = trigger_source
    @queue_operations = []
    @queue_entry_count = 0
    @queue_exit_count = 0
    @recovery_attempts = 0
    @timeout_events = 0
    @log_entry = nil
    @config = matching_log_config

    create_log_entry if @config.persist_started
  end

  # 记录队列进入操作
  def log_queue_entry(order_hashes, from_status, to_status)
    operation = {
      timestamp: Time.current.iso8601,
      operation: 'queue_entry',
      order_count: order_hashes.size,
      order_hashes: compact_order_hashes(order_hashes),
      from_status: from_status,
      to_status: to_status
    }

    append_operation(operation)
    @queue_entry_count += 1

    Rails.logger.info "[QUEUE:#{@market_id}] 入队: #{order_hashes.size}个订单 #{from_status} → #{to_status}"
  end

  # 记录队列退出操作
  def log_queue_exit(order_hashes, result, destination = nil)
    operation = {
      timestamp: Time.current.iso8601,
      operation: 'queue_exit',
      order_count: order_hashes.size,
      order_hashes: compact_order_hashes(order_hashes),
      result: result,
      destination: destination
    }

    append_operation(operation)
    @queue_exit_count += 1

    destination_info = destination ? " → #{destination}" : ''
    Rails.logger.info "[QUEUE:#{@market_id}] 出队: #{order_hashes.size}个订单, 结果:#{result}#{destination_info}"
  end

  # 记录恢复操作
  def log_recovery_attempt(order_hashes, recovery_type, result)
    operation = {
      timestamp: Time.current.iso8601,
      operation: 'recovery',
      order_count: order_hashes.size,
      order_hashes: compact_order_hashes(order_hashes),
      recovery_type: recovery_type,
      result: result
    }

    append_operation(operation)
    @recovery_attempts += 1

    Rails.logger.info "[RECOVERY:#{@market_id}] #{recovery_type}: #{order_hashes.size}个订单, 结果:#{result}"
  end

  # 记录会话成功完成
  def log_session_success(summary = {})
    complete_session('completed', summary)
    Rails.logger.info "[SESSION:#{@market_id}] 队列处理成功 - #{summary[:description] || '已完成'}"
  end

  # 记录会话失败
  def log_session_failure(error)
    error_summary = {
      error_message: error.message,
      error_class: error.class.name
    }

    complete_session('failed', error_summary)
    Rails.logger.error "[SESSION:#{@market_id}] 队列处理失败 - #{error.message}"
  end

  # 记录会话取消（无队列操作）
  def log_session_cancelled(reason)
    summary = { cancellation_reason: reason }
    complete_session('cancelled', summary)
    Rails.logger.debug "[SESSION:#{@market_id}] 会话取消 - #{reason}"
  end

  # 记录超时清理操作
  def log_timeout_cleanup(order_hashes, timeout_threshold)
    operation = {
      timestamp: Time.current.iso8601,
      operation: 'timeout_cleanup',
      order_count: order_hashes.size,
      order_hashes: compact_order_hashes(order_hashes),
      timeout_threshold: timeout_threshold,
      result: 'moved_to_recovery_queue'
    }

    append_operation(operation)
    @timeout_events += 1

    Rails.logger.warn "[TIMEOUT:#{@market_id}] 清理超时订单: #{order_hashes.size}个订单"
  end

  # 记录算法降级
  def log_algorithm_fallback(from_algorithm, to_algorithm, reason)
    operation = {
      timestamp: Time.current.iso8601,
      operation: 'algorithm_fallback',
      from_algorithm: from_algorithm,
      to_algorithm: to_algorithm,
      reason: reason
    }

    append_operation(operation)

    Rails.logger.info "[ALGORITHM:#{@market_id}] 算法降级: #{from_algorithm} → #{to_algorithm}, 原因: #{reason}"
  end

  # 记录错误信息（公开方法）
  def log_error(message, details = {})
    Rails.logger.error "[MatchEngine] 错误: #{message}"
    Rails.logger.error "[MatchEngine] 详情: #{details.inspect}"

    append_operation({
      timestamp: Time.current.iso8601,
      operation: 'error',
      message: message,
      details: details
    })

    # 失败类日志需要可追溯，确保立即落库（但只更新错误概要）
    ensure_log_entry!
    error_data = @log_entry.redis_data_stored || {}
    error_data[:error_message] = message
    error_data[:error_details] = details
    @log_entry.update!(
      error_message: message,
      redis_data_stored: error_data
    )
  end

  # 添加警告信息
  def add_warning(message, details = {})
    Rails.logger.warn "[MatchEngine] 警告: #{message}"
    Rails.logger.warn "[MatchEngine] 详情: #{details.inspect}" if details.any?

    # 记录到队列操作中
    append_operation({
      timestamp: Time.current.iso8601,
      operation: 'warning',
      message: message,
      details: details
    })
  end

  private

  def create_log_entry
    @log_entry = Trading::OrderMatchingLog.create!(
      market_id: @market_id,
      matching_session_id: @session_id,
      trigger_source: @trigger_source,
      status: 'started',
      started_at: @start_time,
      worker_id: current_worker_id
    )
  end

  def complete_session(status, summary = {})
    return if should_skip_persistence?(status, summary)

    completion_time = Time.current
    ensure_log_entry!

    matched_groups_count = summary.is_a?(Hash) ? (summary[:matched_groups_count] || summary['matched_groups_count']) : nil
    matched_orders_count = summary.is_a?(Hash) ? (summary[:matched_orders_count] || summary['matched_orders_count']) : nil
    matching_details = summary.is_a?(Hash) ? (summary[:matching_details] || summary['matching_details']) : nil
    completion_attrs = {}
    completion_attrs[:matched_groups_count] = matched_groups_count.to_i unless matched_groups_count.nil?
    completion_attrs[:matched_orders_count] = matched_orders_count.to_i unless matched_orders_count.nil?
    completion_attrs[:matching_details] = matching_details if matching_details.present?
    completion_attrs[:matching_completed_at] = completion_time if status == 'completed'

    @log_entry.update!(
      status: status,
      completed_at: completion_time,
      queue_operations: @queue_operations,
      queue_entry_count: @queue_entry_count,
      queue_exit_count: @queue_exit_count,
      recovery_attempts: @recovery_attempts,
      timeout_events: @timeout_events,
      redis_data_stored: summary,  # 仅存储摘要信息
      **completion_attrs
    )

    @log_entry.save!
  end

  def append_operation(operation)
    @queue_operations << operation
    limit = @config.max_queue_operations.to_i
    return if limit <= 0

    if @queue_operations.size > limit
      @queue_operations.shift(@queue_operations.size - limit)
    end
  end

  def compact_order_hashes(order_hashes)
    return [] unless @config.store_order_hashes

    arr = Array(order_hashes).compact
    max_count = @config.max_order_hashes_per_operation.to_i
    return arr if max_count <= 0

    arr.first(max_count)
  end

  def should_skip_persistence?(status, summary)
    return false unless @config.enabled
    return true if status == 'cancelled' && summary.is_a?(Hash) && summary[:cancellation_reason] == 'no_operations' && !sample_no_op_cancelled?

    false
  end

  def sample_no_op_cancelled?
    rate = @config.cancelled_noop_sampling_rate.to_f
    return false if rate <= 0
    return true if rate >= 1

    rand < rate
  end

  def ensure_log_entry!
    return if @log_entry

    create_log_entry
  end

  def matching_log_config
    base = Rails.application.config.x.match_logging

    OpenStruct.new(
      enabled: base&.enabled != false,
      persist_started: base&.persist_started == true,
      store_order_hashes: base&.store_order_hashes == true,
      max_order_hashes_per_operation: (base&.max_order_hashes_per_operation || 6).to_i,
      max_queue_operations: (base&.max_queue_operations || 80).to_i,
      cancelled_noop_sampling_rate: (base&.cancelled_noop_sampling_rate || 0.02).to_f
    )
  end

  def current_worker_id
    # 检查是否在Sidekiq worker上下文中
    if defined?(Sidekiq::Context) && Sidekiq::Context.current && Sidekiq::Context.current['class']
      "#{Sidekiq::Context.current['class']}:#{Process.pid}"
    elsif defined?(Sidekiq) && Thread.current[:sidekiq_context]
      worker_class = Thread.current[:sidekiq_context]['class'] || 'SidekiqWorker'
      "#{worker_class}:#{Process.pid}"
    else
      "main:#{Process.pid}"
    end
  rescue => e
    # 如果获取worker信息失败，返回默认值
    "unknown:#{Process.pid}"
  end

  # 类方法：便捷的静态日志记录
  class << self
    # 包装执行队列处理过程
    def with_queue_logging(market_id, trigger_source = 'unknown')
      logger = new(market_id, trigger_source)

      begin
        Thread.current[:matching_logger] = logger
        result = yield(logger)
        if result.is_a?(Hash) && result[:success]
          logger.log_session_success(result)
        else
          logger.log_session_cancelled('no_operations')
        end
        result
      rescue => error
        logger.log_session_failure(error)
        raise
      ensure
        Thread.current[:matching_logger] = nil
      end
    end
  end
end
