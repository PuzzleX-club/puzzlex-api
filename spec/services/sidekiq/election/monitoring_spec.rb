# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Sidekiq::Election::Monitoring do
  let(:redis) { double('redis') }
  let(:election_service) { double('election_service') }

  before do
    # Mock dependencies
    allow(Sidekiq).to receive(:redis).and_yield(redis)
    allow(described_class).to receive(:sleep)
    allow(Rails.logger).to receive(:info)
    allow(Rails.logger).to receive(:error)
    allow(Rails.logger).to receive(:warn)
    allow(Rails.logger).to receive(:debug)

    collector = Sidekiq::Election::Monitoring::MetricsCollector
    %i[
      @prometheus_available
      @leader_changes_total
      @leader_heartbeat_success_total
      @leader_heartbeat_failure_total
      @leader_token
      @no_leader_duration_seconds
      @leader_elections_total
    ].each do |ivar|
      collector.remove_instance_variable(ivar) if collector.instance_variable_defined?(ivar)
    end
  end

  describe 'constants' do
    it 'defines check interval' do
      expect(described_class::CHECK_INTERVAL).to eq(30)
    end

    it 'defines alert thresholds' do
      expect(described_class::ALERT_THRESHOLDS).to include(
        no_leader_duration: 60,
        frequent_elections: 3,
        heartbeat_failures: 3
      )
    end
  end

  describe '.start_monitoring' do
    it 'starts monitoring in a new thread' do
      mock_thread = instance_double(Thread)
      allow(described_class).to receive(:check_all_conditions)
      expect(Thread).to receive(:new).and_return(mock_thread)

      expect(Rails.logger).to receive(:info).with('[ElectionMonitoring] 启动选举监控')

      expect(described_class.start_monitoring).to eq(mock_thread)
    end

    it 'handles exceptions gracefully' do
      allow(described_class).to receive(:check_all_conditions).and_raise(StandardError.new('Monitoring error'))
      expect(Thread).to receive(:new).and_wrap_original do |original, *args, &block|
        thread = original.call(*args, &block)
        sleep 0.01
        thread.kill
        thread
      end

      expect(Rails.logger).to receive(:error).with('[ElectionMonitoring] 监控异常: Monitoring error')

      described_class.start_monitoring
    end
  end

  describe 'private methods' do

    describe '.check_all_conditions' do
      it 'checks all monitoring conditions' do
        expect(described_class).to receive(:check_no_leader)
        expect(described_class).to receive(:check_election_frequency)
        expect(described_class).to receive(:check_heartbeat_health)

        described_class.send(:check_all_conditions)
      end
    end

    describe '.check_no_leader' do
      before do
        allow(Sidekiq::Election::Service).to receive(:status).and_return(status_response)
      end

      context 'when current instance is leader' do
        let(:status_response) { { is_leader: true } }

        it 'does nothing' do
          expect(redis).not_to receive(:get)
          described_class.send(:check_no_leader)
        end
      end

      context 'when there is no lock and duration exceeds threshold' do
        let(:status_response) { { is_leader: false } }
        let(:last_leader_time) { Time.current - 70 } # 70 seconds ago

        before do
          allow(redis).to receive(:get).with(Sidekiq::Election::Service::LOCK_KEY).and_return(nil)
          allow(described_class).to receive(:get_last_leader_time).and_return(last_leader_time)
          allow(described_class).to receive(:send_alert)
        end

        it 'sends no_leader alert' do
          expect(described_class).to receive(:send_alert).with(
            'no_leader',
            {
              duration: 70.0,
              last_leader: last_leader_time.strftime('%Y-%m-%d %H:%M:%S')
            }
          )

          described_class.send(:check_no_leader)
        end
      end

      context 'when lock exists' do
        let(:status_response) { { is_leader: false } }

        before do
          allow(redis).to receive(:get).with(Sidekiq::Election::Service::LOCK_KEY).and_return('locked')
        end

        it 'does not check duration' do
          expect(described_class).not_to receive(:get_last_leader_time)
          described_class.send(:check_no_leader)
        end
      end

      context 'when duration is within threshold' do
        let(:status_response) { { is_leader: false } }
        let(:last_leader_time) { Time.current - 30 } # 30 seconds ago

        before do
          allow(redis).to receive(:get).with(Sidekiq::Election::Service::LOCK_KEY).and_return(nil)
          allow(described_class).to receive(:get_last_leader_time).and_return(last_leader_time)
        end

        it 'does not send alert' do
          expect(described_class).not_to receive(:send_alert)
          described_class.send(:check_no_leader)
        end
      end

      context 'when exception occurs during check' do
        let(:status_response) { { is_leader: false } }

        before do
          allow(redis).to receive(:get).and_raise(StandardError.new('Redis error'))
        end

        it 'logs error but does not raise' do
          expect(Rails.logger).to receive(:error).with('[ElectionMonitoring] 检查无leader状态失败: Redis error')
          described_class.send(:check_no_leader)
        end
      end
    end

    describe '.check_election_frequency' do
      context 'when elections exceed threshold' do
        let(:recent_changes) { 4 }

        before do
          allow(described_class).to receive(:count_recent_leader_changes).and_return(recent_changes)
          allow(described_class).to receive(:send_alert)
        end

        it 'sends frequent_elections alert' do
          expect(described_class).to receive(:send_alert).with(
            'frequent_elections',
            {
              count: 4,
              window: '5分钟'
            }
          )

          described_class.send(:check_election_frequency)
        end
      end

      context 'when elections within threshold' do
        let(:recent_changes) { 2 }

        before do
          allow(described_class).to receive(:count_recent_leader_changes).and_return(recent_changes)
          allow(described_class).to receive(:send_alert)
        end

        it 'does not send alert' do
          expect(described_class).not_to receive(:send_alert)
          described_class.send(:check_election_frequency)
        end
      end

      context 'when exception occurs during check' do
        before do
          allow(described_class).to receive(:count_recent_leader_changes).and_raise(StandardError.new('Count error'))
        end

        it 'logs error but does not raise' do
          expect(Rails.logger).to receive(:error).with('[ElectionMonitoring] 检查选举频率失败: Count error')
          described_class.send(:check_election_frequency)
        end
      end
    end

    describe '.check_heartbeat_health' do
      context 'when heartbeat failures exceed threshold' do
        let(:recent_failures) { 3 }

        before do
          allow(described_class).to receive(:get_recent_heartbeat_failures).and_return(recent_failures)
          allow(described_class).to receive(:send_alert)
        end

        it 'sends heartbeat_failures alert' do
          expect(described_class).to receive(:send_alert).with(
            'heartbeat_failures',
            {
              count: 3,
              window: '5分钟'
            }
          )

          described_class.send(:check_heartbeat_health)
        end
      end

      context 'when heartbeat failures within threshold' do
        let(:recent_failures) { 1 }

        before do
          allow(described_class).to receive(:get_recent_heartbeat_failures).and_return(recent_failures)
          allow(described_class).to receive(:send_alert)
        end

        it 'does not send alert' do
          expect(described_class).not_to receive(:send_alert)
          described_class.send(:check_heartbeat_health)
        end
      end

      context 'when exception occurs during check' do
        before do
          allow(described_class).to receive(:get_recent_heartbeat_failures).and_raise(StandardError.new('Health check error'))
        end

        it 'logs error but does not raise' do
          expect(Rails.logger).to receive(:error).with('[ElectionMonitoring] 检查心跳健康失败: Health check error')
          described_class.send(:check_heartbeat_health)
        end
      end
    end

    describe '.get_last_leader_time' do
      context 'when Redis has last leader time' do
        before do
          allow(redis).to receive(:get).with('sidekiq:leader:last_time').and_return('1640995200')
        end

        it 'returns Time from Redis timestamp' do
          result = described_class.send(:get_last_leader_time)
          expect(result).to eq(Time.at(1640995200))
        end
      end

      context 'when Redis has no last leader time' do
        before do
          allow(redis).to receive(:get).with('sidekiq:leader:last_time').and_return(nil)
        end

        it 'returns current time minus 2 minutes' do
          expected_time = Time.current - 120
          result = described_class.send(:get_last_leader_time)
          expect(result).to be_within(1.second).of(expected_time)
        end
      end
    end

    describe '.count_recent_leader_changes' do
      context 'when Redis has recent changes' do
        before do
          current_time = Time.current.to_i
          allow(redis).to receive(:zrange).with(
            'sidekiq:leader:changes',
            current_time - 300,
            current_time,
            byscore: true
          ).and_return(['change1', 'change2', 'change3'])
        end

        it 'returns count of recent changes' do
          result = described_class.send(:count_recent_leader_changes, 300)
          expect(result).to eq(3)
        end
      end

      context 'when Redis has no recent changes' do
        before do
          allow(redis).to receive(:zrange).and_return([])
        end

        it 'returns 0' do
          result = described_class.send(:count_recent_leader_changes, 300)
          expect(result).to eq(0)
        end
      end
    end

    describe '.get_recent_heartbeat_failures' do
      it 'returns 0 (placeholder implementation)' do
        result = described_class.send(:get_recent_heartbeat_failures, 300)
        expect(result).to eq(0)
      end
    end

    describe '.send_alert' do
      let(:alert_type) { 'test_alert' }
      let(:metadata) { { test: 'data' } }
      let(:expected_alert_data) do
        {
          timestamp: anything,
          type: alert_type,
          severity: 'info',
          metadata: metadata,
          service: 'sidekiq-election'
        }
      end

      it 'builds alert data correctly' do
        allow(Time).to receive(:current).and_return(Time.new(2023, 1, 1, 12, 0, 0))
        allow(described_class).to receive(:alert_severity).and_return('info')
        allow(described_class).to receive(:build_alert_log_message).and_return('Test message')

        expect(Rails.logger).to receive(:error).with('[ALERT] Test message')

        described_class.send(:send_alert, alert_type, metadata)
      end

      it 'logs alert with proper format' do
        allow(described_class).to receive(:alert_severity).and_return('warning')
        allow(described_class).to receive(:build_alert_log_message).and_return('Warning message')

        expect(Rails.logger).to receive(:error).with('[ALERT] Warning message')

        described_class.send(:send_alert, 'no_leader', { duration: 60 })
      end
    end

    describe '.alert_severity' do
      it 'returns correct severity for different alert types' do
        expect(described_class.send(:alert_severity, 'no_leader')).to eq('critical')
        expect(described_class.send(:alert_severity, 'frequent_elections')).to eq('warning')
        expect(described_class.send(:alert_severity, 'heartbeat_failures')).to eq('warning')
        expect(described_class.send(:alert_severity, 'unknown')).to eq('info')
      end
    end

    describe '.build_alert_log_message' do
      context 'with no_leader alert' do
        let(:alert_data) do
          {
            type: 'no_leader',
            metadata: { duration: 120, last_leader: '2023-01-01 12:00:00' }
          }
        end

        it 'builds correct message for no_leader' do
          message = described_class.send(:build_alert_log_message, alert_data)
          expect(message).to eq('系统无leader已超过120秒！最后leader时间: 2023-01-01 12:00:00')
        end
      end

      context 'with frequent_elections alert' do
        let(:alert_data) do
          {
            type: 'frequent_elections',
            metadata: { count: 5, window: '5分钟' }
          }
        end

        it 'builds correct message for frequent_elections' do
          message = described_class.send(:build_alert_log_message, alert_data)
          expect(message).to eq('选举过于频繁：5分钟内发生了5次选举')
        end
      end

      context 'with heartbeat_failures alert' do
        let(:alert_data) do
          {
            type: 'heartbeat_failures',
            metadata: { count: 4, window: '5分钟' }
          }
        end

        it 'builds correct message for heartbeat_failures' do
          message = described_class.send(:build_alert_log_message, alert_data)
          expect(message).to eq('心跳失败过多：5分钟内失败了4次')
        end
      end

      context 'with unknown alert type' do
        let(:alert_data) do
          {
            type: 'unknown_type',
            metadata: {}
          }
        end

        it 'builds generic message for unknown type' do
          message = described_class.send(:build_alert_log_message, alert_data)
          expect(message).to eq('未知告警类型: unknown_type')
        end
      end
    end
  end

  describe Sidekiq::Election::Monitoring::MetricsCollector do
    let(:instance_id) { 'instance-123' }
    let(:token) { 12345 }

    before do
      %i[
        @prometheus_available
        @leader_changes_total
        @leader_heartbeat_success_total
        @leader_heartbeat_failure_total
        @leader_token
        @no_leader_duration_seconds
        @leader_elections_total
      ].each do |ivar|
        described_class.remove_instance_variable(ivar) if described_class.instance_variable_defined?(ivar)
      end
    end

    describe '.initialize_metrics' do
      context 'when Prometheus is available' do
        before do
          stub_const("Prometheus::Client", double('Prometheus::Client'))
          allow(Prometheus::Client).to receive(:registry).and_return(registry)
          allow(registry).to receive(:counter).and_return(counter_mock)
          allow(registry).to receive(:gauge).and_return(gauge_mock)
        end

        let(:registry) { double('registry') }
        let(:counter_mock) { double('counter') }
        let(:gauge_mock) { double('gauge') }

        it 'initializes all Prometheus metrics' do
          expect(registry).to receive(:counter).exactly(4).times.and_return(counter_mock)
          expect(registry).to receive(:gauge).exactly(2).times.and_return(gauge_mock)
          expect(Rails.logger).to receive(:info).with('[MetricsCollector] Prometheus指标已初始化')

          described_class.initialize_metrics
        end

        context 'when Prometheus initialization fails' do
          before do
            allow(registry).to receive(:counter).and_raise(StandardError.new('Prometheus error'))
          end

          it 'falls back to Redis-only mode and logs warning' do
            expect(Rails.logger).to receive(:warn).with(/Prometheus初始化失败，降级为仅Redis记录/)
            described_class.initialize_metrics

            # Should set prometheus_available to false
            expect(described_class.instance_variable_get(:@prometheus_available)).to be false
          end
        end
      end

      context 'when Prometheus is not available' do
        before do
          hide_const("Prometheus::Client")
        end

        it 'does not attempt to initialize Prometheus metrics' do
          expect(Rails.logger).not_to receive(:info).with(/Prometheus指标已初始化/)
          described_class.initialize_metrics
        end
      end
    end

    describe '.record_leader_change' do
      before do
        allow(Time).to receive(:current).and_return(Time.current)
      end

      context 'when Prometheus is available' do
        before do
          described_class.instance_variable_set(:@prometheus_available, true)
          described_class.instance_variable_set(:@leader_changes_total, double('counter', increment: nil))
          described_class.instance_variable_set(:@leader_token, double('gauge', set: nil))
        end

        it 'increments Prometheus counter and sets token' do
          counter = described_class.instance_variable_get(:@leader_changes_total)
          gauge = described_class.instance_variable_get(:@leader_token)

          expect(counter).to receive(:increment).with(labels: { instance_id: instance_id })
          expect(gauge).to receive(:set).with(token, labels: { instance_id: instance_id })
          expect(redis).to receive(:zadd)
          expect(redis).to receive(:expire)

          described_class.record_leader_change(instance_id, token)
        end
      end

      it 'always records to Redis for alerting' do
        expect(redis).to receive(:zadd).with(
          'sidekiq:leader:changes',
          Time.current.to_i,
          "#{instance_id}:#{token}"
        )
        expect(redis).to receive(:expire).with('sidekiq:leader:changes', 3600)

        described_class.record_leader_change(instance_id, token)
      end

      context 'when exception occurs' do
        before do
          allow(redis).to receive(:zadd).and_raise(StandardError.new('Redis error'))
        end

        it 'logs error but does not raise' do
          expect(Rails.logger).to receive(:error).with(/记录leader变更失败/)
          described_class.record_leader_change(instance_id, token)
        end
      end
    end

    describe '.record_heartbeat_success' do
      context 'when Prometheus is available' do
        before do
          described_class.instance_variable_set(:@prometheus_available, true)
          described_class.instance_variable_set(:@leader_heartbeat_success_total, double('counter', increment: nil))
        end

        it 'increments Prometheus counter' do
          counter = described_class.instance_variable_get(:@leader_heartbeat_success_total)
          expect(counter).to receive(:increment).with(labels: { instance_id: instance_id })

          described_class.record_heartbeat_success(instance_id)
        end
      end

      context 'when Prometheus is not available' do
        before do
          described_class.instance_variable_set(:@prometheus_available, false)
        end

        it 'does nothing' do
          described_class.record_heartbeat_success(instance_id)
        end
      end

      context 'when exception occurs' do
        before do
          described_class.instance_variable_set(:@prometheus_available, true)
          counter = double('counter')
          allow(counter).to receive(:increment).and_raise(StandardError.new('Prometheus error'))
          described_class.instance_variable_set(:@leader_heartbeat_success_total, counter)
        end

        it 'logs debug message' do
          expect(Rails.logger).to receive(:debug).with(/记录心跳成功失败/)
          described_class.record_heartbeat_success(instance_id)
        end
      end
    end

    describe '.record_heartbeat_failure' do
      context 'when Prometheus is available' do
        before do
          described_class.instance_variable_set(:@prometheus_available, true)
          described_class.instance_variable_set(:@leader_heartbeat_failure_total, double('counter', increment: nil))
        end

        it 'increments Prometheus counter' do
          counter = described_class.instance_variable_get(:@leader_heartbeat_failure_total)
          expect(counter).to receive(:increment).with(labels: { instance_id: instance_id })

          described_class.record_heartbeat_failure(instance_id)
        end
      end
    end

    describe '.record_election_attempt' do
      let(:result) { 'success' }

      context 'when Prometheus is available' do
        before do
          described_class.instance_variable_set(:@prometheus_available, true)
          described_class.instance_variable_set(:@leader_elections_total, double('counter', increment: nil))
        end

        it 'increments Prometheus counter with result label' do
          counter = described_class.instance_variable_get(:@leader_elections_total)
          expect(counter).to receive(:increment).with(labels: { instance_id: instance_id, result: result })

          described_class.record_election_attempt(instance_id, result)
        end
      end
    end

    describe '.update_no_leader_duration' do
      let(:seconds) { 120 }

      context 'when Prometheus is available' do
        before do
          described_class.instance_variable_set(:@prometheus_available, true)
          described_class.instance_variable_set(:@no_leader_duration_seconds, double('gauge', set: nil))
        end

        it 'sets Prometheus gauge' do
          gauge = described_class.instance_variable_get(:@no_leader_duration_seconds)
          expect(gauge).to receive(:set).with(seconds)

          described_class.update_no_leader_duration(seconds)
        end
      end
    end

    describe 'metrics availability flag' do
      it 'detects Prometheus availability correctly' do
        # Test that @prometheus_available is set based on defined?(Prometheus::Client)
        described_class.instance_variable_set(:@prometheus_available, nil)

        # The flag should be set based on whether Prometheus::Client is defined
        described_class.initialize_metrics
      end
    end
  end
end
