require 'rails_helper'

RSpec.describe Matching::State::Logger, type: :service do
  let(:market_id) { 'test_market_001' }
  let(:trigger_source) { 'manual' }

  before do
    # 使用 ServiceTestHelpers 提供的 stub 方法
    stub_redis
    stub_action_cable
    stub_sidekiq_workers

    # 启用 persist_started 以便测试 log_entry 创建
    match_logging_config = ActiveSupport::OrderedOptions.new
    match_logging_config.enabled = true
    match_logging_config.persist_started = true
    match_logging_config.store_order_hashes = true
    match_logging_config.max_order_hashes_per_operation = 6
    match_logging_config.max_queue_operations = 80
    match_logging_config.cancelled_noop_sampling_rate = 0.02
    allow(Rails.application.config.x).to receive(:match_logging).and_return(match_logging_config)

    # 清理测试数据
    Trading::OrderMatchingLog.delete_all
  end

  # 需要在 before 之后创建 logger，确保 config stub 已生效
  let(:logger) { described_class.new(market_id, trigger_source) }

  describe '#initialize' do
    it '创建日志条目和设置初始状态' do
      expect(logger.market_id).to eq(market_id)
      expect(logger.session_id).to be_present
      expect(logger.log_entry).to be_persisted
      expect(logger.log_entry.status).to eq('started')
      expect(logger.log_entry.market_id).to eq(market_id)
      expect(logger.log_entry.trigger_source).to eq(trigger_source)
    end

    it '生成唯一的会话ID' do
      logger1 = described_class.new(market_id, trigger_source)
      logger2 = described_class.new(market_id, trigger_source)

      expect(logger1.session_id).not_to eq(logger2.session_id)
    end

    context '当 persist_started 为 false 时' do
      before do
        config = ActiveSupport::OrderedOptions.new
        config.enabled = true
        config.persist_started = false
        config.store_order_hashes = false
        config.max_order_hashes_per_operation = 6
        config.max_queue_operations = 80
        config.cancelled_noop_sampling_rate = 0.02
        allow(Rails.application.config.x).to receive(:match_logging).and_return(config)
      end

      it '不立即创建日志条目' do
        new_logger = described_class.new(market_id, trigger_source)
        expect(new_logger.log_entry).to be_nil
      end
    end
  end

  describe '#log_queue_entry' do
    let(:order_hashes) { ['0xhash1', '0xhash2', '0xhash3'] }

    it '记录入队操作' do
      logger.log_queue_entry(order_hashes, 'active', 'matching')

      expect(logger.send(:instance_variable_get, :@queue_entry_count)).to eq(1)
      operations = logger.send(:instance_variable_get, :@queue_operations)
      expect(operations.size).to eq(1)

      op = operations.first
      expect(op[:operation]).to eq('queue_entry')
      expect(op[:order_count]).to eq(3)
      expect(op[:from_status]).to eq('active')
      expect(op[:to_status]).to eq('matching')
      expect(op[:timestamp]).to be_present
    end
  end

  describe '#log_queue_exit' do
    let(:order_hashes) { ['0xhash1', '0xhash2'] }

    it '记录出队操作' do
      logger.log_queue_exit(order_hashes, 'success', 'executor')

      expect(logger.send(:instance_variable_get, :@queue_exit_count)).to eq(1)
      operations = logger.send(:instance_variable_get, :@queue_operations)
      expect(operations.size).to eq(1)

      op = operations.first
      expect(op[:operation]).to eq('queue_exit')
      expect(op[:order_count]).to eq(2)
      expect(op[:result]).to eq('success')
      expect(op[:destination]).to eq('executor')
    end
  end

  describe '#log_recovery_attempt' do
    let(:order_hashes) { ['0xhash1'] }

    it '记录恢复操作' do
      logger.log_recovery_attempt(order_hashes, 'timeout_recovery', 'restored')

      expect(logger.send(:instance_variable_get, :@recovery_attempts)).to eq(1)
      operations = logger.send(:instance_variable_get, :@queue_operations)
      expect(operations.size).to eq(1)

      op = operations.first
      expect(op[:operation]).to eq('recovery')
      expect(op[:recovery_type]).to eq('timeout_recovery')
      expect(op[:result]).to eq('restored')
    end
  end

  describe '#log_timeout_cleanup' do
    let(:order_hashes) { ['0xhash1', '0xhash2'] }

    it '记录超时清理操作' do
      logger.log_timeout_cleanup(order_hashes, 300)

      expect(logger.send(:instance_variable_get, :@timeout_events)).to eq(1)
      operations = logger.send(:instance_variable_get, :@queue_operations)
      expect(operations.size).to eq(1)

      op = operations.first
      expect(op[:operation]).to eq('timeout_cleanup')
      expect(op[:timeout_threshold]).to eq(300)
      expect(op[:result]).to eq('moved_to_recovery_queue')
    end
  end

  describe '#log_session_success' do
    it '记录成功完成并保存到数据库' do
      summary = {
        description: '撮合完成',
        matched_groups_count: 3,
        matched_orders_count: 8
      }

      logger.log_session_success(summary)

      logger.log_entry.reload
      expect(logger.log_entry.status).to eq('completed')
      expect(logger.log_entry.completed_at).to be_present
      expect(logger.log_entry.matching_completed_at).to be_present
      expect(logger.log_entry.matched_groups_count).to eq(3)
      expect(logger.log_entry.matched_orders_count).to eq(8)
      expect(logger.log_entry.redis_data_stored).to be_present
    end

    it '处理空摘要' do
      logger.log_session_success({})

      logger.log_entry.reload
      expect(logger.log_entry.status).to eq('completed')
      expect(logger.log_entry.completed_at).to be_present
    end
  end

  describe '#log_session_failure' do
    let(:error) { StandardError.new("测试错误") }

    it '记录失败信息' do
      logger.log_session_failure(error)

      logger.log_entry.reload
      expect(logger.log_entry.status).to eq('failed')
      expect(logger.log_entry.completed_at).to be_present
      expect(logger.log_entry.redis_data_stored).to include(
        'error_message' => '测试错误',
        'error_class' => 'StandardError'
      )
    end
  end

  describe '#log_session_cancelled' do
    let(:reason) { "无有效订单可撮合" }

    it '记录取消信息' do
      logger.log_session_cancelled(reason)

      logger.log_entry.reload
      expect(logger.log_entry.status).to eq('cancelled')
      expect(logger.log_entry.completed_at).to be_present
      expect(logger.log_entry.redis_data_stored).to include(
        'cancellation_reason' => reason
      )
    end
  end

  describe '#log_error' do
    it '记录错误到操作历史并更新数据库' do
      logger.log_error("匹配失败", { order_hash: '0xabc' })

      logger.log_entry.reload
      expect(logger.log_entry.error_message).to eq("匹配失败")

      operations = logger.send(:instance_variable_get, :@queue_operations)
      error_op = operations.find { |op| op[:operation] == 'error' }
      expect(error_op).to be_present
      expect(error_op[:message]).to eq("匹配失败")
    end
  end

  describe '#add_warning' do
    let(:warning_message) { "算法性能警告" }
    let(:warning_details) { { threshold: 1000, actual: 1500 } }

    it '添加警告到操作历史' do
      logger.add_warning(warning_message, warning_details)

      operations = logger.send(:instance_variable_get, :@queue_operations)
      expect(operations.size).to eq(1)

      warning = operations.first
      expect(warning[:operation]).to eq('warning')
      expect(warning[:message]).to eq(warning_message)
      expect(warning[:details]).to eq(warning_details)
      expect(warning[:timestamp]).to be_present
    end

    it '支持多个警告' do
      logger.add_warning("警告1", { type: 'performance' })
      logger.add_warning("警告2", { type: 'memory' })

      operations = logger.send(:instance_variable_get, :@queue_operations)
      warning_ops = operations.select { |op| op[:operation] == 'warning' }
      expect(warning_ops.size).to eq(2)
    end
  end

  describe '#log_algorithm_fallback' do
    it '记录算法降级到操作历史' do
      logger.log_algorithm_fallback('dp', 'recursive', '内存限制')

      operations = logger.send(:instance_variable_get, :@queue_operations)
      expect(operations.size).to eq(1)

      fallback = operations.first
      expect(fallback[:operation]).to eq('algorithm_fallback')
      expect(fallback[:from_algorithm]).to eq('dp')
      expect(fallback[:to_algorithm]).to eq('recursive')
      expect(fallback[:reason]).to eq('内存限制')
    end
  end

  describe '类方法' do
    describe '.with_queue_logging' do
      it '自动记录成功的队列处理过程' do
        result = described_class.with_queue_logging(market_id, 'manual') do |log|
          expect(log).to be_a(described_class)
          { success: true, description: '处理完成' }
        end

        expect(result[:success]).to be true

        log_entry = Trading::OrderMatchingLog.last
        expect(log_entry.status).to eq('completed')
        expect(log_entry.market_id).to eq(market_id)
      end

      it '当 block 返回非成功结果时记录取消' do
        # cancelled_noop_sampling_rate 需要设为 1.0 以确保 no_operations 取消会被持久化
        config = ActiveSupport::OrderedOptions.new
        config.enabled = true
        config.persist_started = true
        config.store_order_hashes = true
        config.max_order_hashes_per_operation = 6
        config.max_queue_operations = 80
        config.cancelled_noop_sampling_rate = 1.0
        allow(Rails.application.config.x).to receive(:match_logging).and_return(config)

        result = described_class.with_queue_logging(market_id, 'manual') do |log|
          { success: false }
        end

        expect(result[:success]).to be false

        log_entry = Trading::OrderMatchingLog.last
        expect(log_entry.status).to eq('cancelled')
      end

      it '自动记录失败的队列处理过程' do
        expect {
          described_class.with_queue_logging(market_id, 'manual') do |log|
            raise StandardError, "测试异常"
          end
        }.to raise_error(StandardError, "测试异常")

        log_entry = Trading::OrderMatchingLog.last
        expect(log_entry.status).to eq('failed')
      end
    end
  end

  describe '模型性能方法' do
    let(:log_entry) do
      Trading::OrderMatchingLog.create!(
        market_id: market_id,
        matching_session_id: SecureRandom.uuid,
        trigger_source: trigger_source,
        status: 'completed',
        started_at: Time.current,
        completed_at: Time.current
      )
    end

    describe '#matching_efficiency' do
      it '计算撮合效率' do
        log_entry.update!(
          input_bids_count: 5,
          input_asks_count: 5,
          matched_orders_count: 6
        )

        efficiency = log_entry.matching_efficiency
        expect(efficiency).to eq(60.0)  # 6/10 * 100
      end

      it '当输入为零时返回0' do
        log_entry.update!(input_bids_count: 0, input_asks_count: 0)
        expect(log_entry.matching_efficiency).to eq(0)
      end
    end

    describe '#filter_rate' do
      it '计算过滤率' do
        log_entry.update!(
          input_bids_count: 6,
          input_asks_count: 4,
          filtered_bids_count: 2,
          filtered_asks_count: 1
        )

        filter_rate = log_entry.filter_rate
        expect(filter_rate).to eq(30.0)  # 3/10 * 100
      end
    end

    describe '#performance_rating' do
      it '根据耗时评估性能' do
        # 优秀 (0-500ms)
        log_entry.update!(total_duration_ms: 300)
        expect(log_entry.performance_rating).to eq('excellent')

        # 良好 (501-1000ms)
        log_entry.update!(total_duration_ms: 800)
        expect(log_entry.performance_rating).to eq('good')

        # 可接受 (1001-3000ms)
        log_entry.update!(total_duration_ms: 2000)
        expect(log_entry.performance_rating).to eq('acceptable')

        # 慢 (3001-10000ms)
        log_entry.update!(total_duration_ms: 5000)
        expect(log_entry.performance_rating).to eq('slow')

        # 很慢 (>10000ms)
        log_entry.update!(total_duration_ms: 15000)
        expect(log_entry.performance_rating).to eq('very_slow')
      end
    end
  end

  describe '操作历史限制' do
    it '限制操作历史记录数量' do
      # max_queue_operations 配置为 80，测试超过限制
      config = ActiveSupport::OrderedOptions.new
      config.enabled = true
      config.persist_started = true
      config.store_order_hashes = true
      config.max_order_hashes_per_operation = 6
      config.max_queue_operations = 5
      config.cancelled_noop_sampling_rate = 0.02
      allow(Rails.application.config.x).to receive(:match_logging).and_return(config)

      limited_logger = described_class.new(market_id, trigger_source)

      8.times do |i|
        limited_logger.add_warning("警告#{i}", {})
      end

      operations = limited_logger.send(:instance_variable_get, :@queue_operations)
      expect(operations.size).to eq(5)
    end
  end
end
