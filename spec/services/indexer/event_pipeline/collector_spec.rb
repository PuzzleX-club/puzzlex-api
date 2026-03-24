# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Indexer::EventPipeline::Collector, type: :service do
  let(:rpc_url) { 'https://rpc.example.com' }
  let(:subscription) { create(:onchain_event_subscription) }
  let(:subscriptions) { [subscription] }
  let(:collector) { described_class.new(subscriptions: subscriptions, rpc_url: rpc_url) }

  before do
    Rails.application.config.x.blockchain.rpc_url = rpc_url
    allow(Redis).to receive(:current).and_return(double('redis', sadd: true))
  end

  describe 'constants' do
    it 'defines configurable constants' do
      expect(described_class::MAX_CONSECUTIVE_FAILURES).to be_an(Integer)
      expect(described_class::ERROR_BACKOFF_MAX).to be_a(Float)
      expect(described_class::CATCHUP_THRESHOLD).to be_an(Integer)
    end
  end

  describe 'class methods' do
    describe '.rate_limiter' do
      it 'returns a RateLimiter instance' do
        expect(described_class.rate_limiter).to be_a(Indexer::EventPipeline::RateLimiter)
      end

      it 'returns the same instance (singleton)' do
        limiter1 = described_class.rate_limiter
        limiter2 = described_class.rate_limiter
        expect(limiter1).to eq(limiter2)
      end
    end

    describe '.reset_rate_limiter!' do
      it 'resets the rate limiter instance' do
        limiter = described_class.rate_limiter
        described_class.reset_rate_limiter!
        new_limiter = described_class.rate_limiter
        expect(new_limiter).not_to eq(limiter)
      end
    end
  end

  describe '#initialize' do
    it 'initializes with given subscriptions and RPC URL' do
      expect(collector.instance_variable_get(:@subscriptions)).to eq(subscriptions)
      expect(collector.instance_variable_get(:@rpc_url)).to eq(rpc_url)
    end

    it 'builds a Faraday connection' do
      expect(collector.instance_variable_get(:@connection)).to be_a(Faraday::Connection)
    end

    it 'sets default subscriptions when none provided' do
      expect(Onchain::EventSubscription).to receive(:all).and_return([])
      collector = described_class.new
      expect(collector.instance_variable_get(:@subscriptions)).to eq([])
    end
  end

  describe '#should_run_as_leader?' do
    context 'when current instance is leader' do
      before do
        allow(collector.instance_variable_get(:@election_service)).to receive(:leader?).and_return(true)
      end

      it 'returns true and logs debug message' do
        expect(Rails.logger).to receive(:debug).with(/Leader实例，执行数据收集/)
        expect(collector.should_run_as_leader?).to be true
      end
    end

    context 'when current instance is not leader' do
      before do
        allow(collector.instance_variable_get(:@election_service)).to receive(:leader?).and_return(false)
        allow(collector.instance_variable_get(:@election_service)).to receive(:status).and_return({ token: 'leader_token' })
      end

      it 'returns false and logs info message with leader token' do
        expect(Rails.logger).to receive(:info).with(/非Leader实例，跳过数据收集。当前Leader: leader_token/)
        expect(collector.should_run_as_leader?).to be false
      end
    end
  end

  describe '#run' do
    before do
      allow(collector).to receive(:fetch_latest_block).and_return(1000)
      allow(collector).to receive(:adjust_rps_for_catchup)
      allow(collector).to receive(:cleanup_retention)
      allow(collector).to receive(:log_skipped_subscriptions)
    end

    context 'when not a leader' do
      before do
        allow(collector).to receive(:should_run_as_leader?).and_return(false)
      end

      it 'returns early without processing' do
        expect(collector).not_to receive(:collect_for_subscription)
        collector.run
      end
    end

    context 'when leader but no latest block' do
      before do
        allow(collector).to receive(:should_run_as_leader?).and_return(true)
        allow(collector).to receive(:fetch_latest_block).and_return(nil)
      end

      it 'returns early without processing' do
        expect(collector).not_to receive(:collect_for_subscription)
        collector.run
      end
    end

    context 'when leader with latest block' do
      before do
        allow(collector).to receive(:should_run_as_leader?).and_return(true)
        allow(collector).to receive(:collect_for_subscription)
        election_service = collector.instance_variable_get(:@election_service)
        allow(election_service).to receive(:leader?).and_return(true, false) # Becomes leader, then loses it
      end

      it 'processes subscriptions while leader status is maintained' do
        expect(collector).to receive(:collect_for_subscription).once
        collector.run
      end

      it 'adjusts RPS for catchup' do
        expect(collector).to receive(:adjust_rps_for_catchup).with(1000)
        collector.run
      end

      it 'performs cleanup' do
        expect(collector).to receive(:cleanup_retention)
        collector.run
      end
    end

    context 'with skipped subscriptions' do
      before do
        allow(collector).to receive(:should_run_as_leader?).and_return(true)
        allow(collector).to receive(:collect_for_subscription) do
          collector.instance_variable_get(:@skipped_subscriptions) << { handler_key: 'test', failures: 5 }
        end
      end

      it 'logs skipped subscriptions summary' do
        expect(collector).to receive(:log_skipped_subscriptions)
        collector.run
      end
    end
  end

  describe 'private methods' do

    describe '#build_connection' do
      let(:connection) { collector.send(:build_connection) }

      it 'creates Faraday connection with JSON middleware' do
        expect(connection).to be_a(Faraday::Connection)
        expect(connection.builder.handlers).to include(Faraday::Request::Json)
        expect(connection.builder.handlers).to include(Faraday::Response::Json)
      end

      it 'sets appropriate timeouts' do
        expect(connection.options.timeout).to eq(60)
        expect(connection.options.open_timeout).to eq(15)
      end
    end

    describe '#collect_for_subscription' do
      let(:from_block) { 950 }
      let(:latest_block) { 1000 }
      let(:block_window) { 50 }

      before do
        subscription.update!(start_block: 950, block_window: block_window)
        allow(collector).to receive(:resolve_from_block).and_return(from_block)
        allow(collector).to receive(:persist_logs)
        allow(Onchain::EventListenerStatus).to receive(:update_status)
        election_service = collector.instance_variable_get(:@election_service)
        allow(election_service).to receive(:leader?).and_return(true)
      end

      context 'when from_block > latest_block' do
        let(:from_block) { 1001 }
        let(:block_window) { 100 }

        it 'resets checkpoint to start_block and resumes scanning' do
          expect(Onchain::EventListenerStatus).to receive(:update_status).with(
            "collector:#{subscription.handler_key}",
            950,
            event_type: "collector:#{subscription.handler_key}"
          )
          allow(collector).to receive(:fetch_logs).and_return([])
          expect(collector).to receive(:fetch_logs).with(subscription, 950, 1000).once.and_return([])
          collector.send(:collect_for_subscription, subscription, latest_block)
        end
      end

      context 'when successful log fetching' do
        before do
          allow(collector).to receive(:fetch_logs).and_return([])
        end

        it 'processes blocks in windows' do
          expect(collector).to receive(:fetch_logs).with(subscription, 950, 999).once
          collector.send(:collect_for_subscription, subscription, latest_block)
        end

        it 'updates listener status after successful fetch' do
          expect(Onchain::EventListenerStatus).to receive(:update_status).with("collector:#{subscription.handler_key}", 999, event_type: "collector:#{subscription.handler_key}")
          collector.send(:collect_for_subscription, subscription, latest_block)
        end
      end

      context 'when log fetching fails but recovers' do
        let(:block_window) { 100 }

        before do
          attempts = 0
          allow(collector).to receive(:fetch_logs) do
            attempts += 1
            raise StandardError, 'RPC Error' if attempts == 1

            []
          end
          allow(collector).to receive(:calculate_backoff).and_return(1)
          allow(collector).to receive(:log_rate_limit_error)
          allow(collector).to receive(:sleep)
        end

        it 'retries with backoff' do
          expect(collector).to receive(:sleep).with(1)
          expect(collector).to receive(:log_rate_limit_error).once
          collector.send(:collect_for_subscription, subscription, latest_block)
        end
      end

      context 'when consecutive failures exceed threshold' do
        before do
          allow(collector).to receive(:fetch_logs).and_raise(StandardError.new('Persistent Error'))
          allow(collector).to receive(:calculate_backoff).and_return(1)
          allow(collector).to receive(:log_rate_limit_error)
          allow(collector).to receive(:skip_subscription)
          allow(collector).to receive(:sleep)
        end

        it 'skips subscription after max consecutive failures' do
          stub_const("Indexer::EventPipeline::Collector::MAX_CONSECUTIVE_FAILURES", 2)

          # Simulate 2 failures to reach threshold
          expect(collector).to receive(:skip_subscription).with(subscription, 2)
          collector.send(:collect_for_subscription, subscription, latest_block)
        end
      end

      context 'when leader status is lost during processing' do
        before do
          election_service = collector.instance_variable_get(:@election_service)
          allow(election_service).to receive(:leader?).and_return(true, false)
          allow(collector).to receive(:fetch_logs).and_return([])
        end

        it 'breaks out of loop when losing leader status' do
          expect(collector).to receive(:fetch_logs).once
          collector.send(:collect_for_subscription, subscription, latest_block)
        end
      end
    end

    describe '#calculate_backoff' do
      it 'calculates backoff times correctly' do
        expect(collector.send(:calculate_backoff, 1)).to eq(1)
        expect(collector.send(:calculate_backoff, 2)).to eq(2)
        expect(collector.send(:calculate_backoff, 3)).to eq(5)
        expect(collector.send(:calculate_backoff, 4)).to eq(10)
        expect(collector.send(:calculate_backoff, 5)).to eq(20)
        expect(collector.send(:calculate_backoff, 6)).to eq(30)
        expect(collector.send(:calculate_backoff, 10)).to eq(30) # Capped at max
      end

      it 'respects ERROR_BACKOFF_MAX configuration' do
        stub_const("Indexer::EventPipeline::Collector::ERROR_BACKOFF_MAX", 15)
        expect(collector.send(:calculate_backoff, 5)).to eq(15) # Capped at 15 instead of 20
      end
    end

    describe '#adjust_rps_for_catchup' do
      let(:subscription1) { create(:onchain_event_subscription, start_block: 900) }
      let(:subscription2) { create(:onchain_event_subscription, start_block: 950) }
      let(:subscriptions) { [subscription1, subscription2] }

      before do
        # Mock status lookup to return different blocks behind
        allow(Onchain::EventListenerStatus).to receive(:last_block).and_return("earliest", "900")
        allow(ENV).to receive(:fetch).with("LOG_COLLECTOR_RPS", "5").and_return("5")
        allow(ENV).to receive(:fetch).with("LOG_COLLECTOR_CATCHUP_RPS", "10").and_return("10")
      end

      it 'calculates blocks behind and adjusts RPS' do
        rate_limiter = double('rate_limiter', rps: 5, update_rps: nil, status: { rps: 5, tokens: 100 })
        allow(described_class).to receive(:rate_limiter).and_return(rate_limiter)

        # subscription1: 1000 - 900 = 100 blocks behind (normal mode)
        # subscription2: 1000 - 950 = 50 blocks behind (normal mode)
        # max_blocks_behind = 100, so should stay at base RPS

        expect(rate_limiter).not_to receive(:update_rps)
        collector.send(:adjust_rps_for_catchup, 1000)
      end

      it 'updates RPS when catchup is needed' do
        rate_limiter = double('rate_limiter', rps: 5, update_rps: 8, status: { rps: 5, tokens: 100 })
        allow(described_class).to receive(:rate_limiter).and_return(rate_limiter)

        allow(collector).to receive(:resolve_from_block).and_return(400, 800)

        expect(rate_limiter).to receive(:update_rps).with(8)
        expect(Rails.logger).to receive(:info).with(/blocks_behind=\d+ rps=\d+->8/)
        collector.send(:adjust_rps_for_catchup, 1000)
      end
    end

    describe '#calculate_catchup_rps' do
      before do
        allow(ENV).to receive(:fetch).with("LOG_COLLECTOR_RPS", "5").and_return("5")
        allow(ENV).to receive(:fetch).with("LOG_COLLECTOR_CATCHUP_RPS", "10").and_return("10")
      end

      it 'returns base RPS for normal mode' do
        expect(collector.send(:calculate_catchup_rps, 100)).to eq(5.0)
        expect(collector.send(:calculate_catchup_rps, 500)).to eq(5.0)
      end

      it 'returns moderate RPS for light catchup' do
        expect(collector.send(:calculate_catchup_rps, 501)).to eq(8.0)
        expect(collector.send(:calculate_catchup_rps, 1500)).to eq(8.0)
        expect(collector.send(:calculate_catchup_rps, 2000)).to eq(8.0)
      end

      it 'returns catchup RPS for heavy catchup' do
        expect(collector.send(:calculate_catchup_rps, 2001)).to eq(10.0)
        expect(collector.send(:calculate_catchup_rps, 10000)).to eq(10.0)
      end
    end

    describe '#skip_subscription' do
      it 'adds subscription to skipped list' do
        collector.send(:skip_subscription, subscription, 5)

        skipped = collector.instance_variable_get(:@skipped_subscriptions)
        expect(skipped).to include({
          handler_key: subscription.handler_key,
          failures: 5
        })
      end

      it 'logs skip reason' do
        expect(Rails.logger).to receive(:error).with(/\[SKIP\] handler=#{subscription.handler_key} failures=5/)
        collector.send(:skip_subscription, subscription, 5)
      end

      it 'adds to Redis skipped set' do
        redis = double('redis')
        expect(Sidekiq).to receive(:redis).and_yield(redis)
        expect(redis).to receive(:sadd).with("indexer_event_collector:skipped", subscription.handler_key)
        collector.send(:skip_subscription, subscription, 5)
      end
    end

    describe '#log_skipped_subscriptions' do
      it 'logs summary when there are skipped subscriptions' do
        collector.instance_variable_set(:@skipped_subscriptions, [
          { handler_key: 'handler1', failures: 5 },
          { handler_key: 'handler2', failures: 3 }
        ])

        expect(Rails.logger).to receive(:warn).with(/\[SUMMARY\] skipped_handlers=handler1,handler2 count=2/)
        collector.send(:log_skipped_subscriptions)
      end

      it 'does nothing when no skipped subscriptions' do
        expect(Rails.logger).not_to receive(:warn)
        collector.send(:log_skipped_subscriptions)
      end
    end

    describe '#log_rate_limit_error' do
      let(:error) { StandardError.new('Rate limited') }
      let(:rate_limiter) { double('rate_limiter', status: { rps: 8.0, tokens: 50 }) }

      before do
        allow(described_class).to receive(:rate_limiter).and_return(rate_limiter)
      end

      it 'logs detailed rate limit information' do
        expect(Rails.logger).to receive(:warn).with(
          /\[RATE_LIMIT\] handler=test_handler failures=3 backoff=2s rps=8\.0 tokens=50 error=StandardError/
        )
        collector.send(:log_rate_limit_error, 'test_handler', 3, 2, error)
      end
    end

    describe '#resolve_from_block' do
      before do
        allow(Onchain::EventListenerStatus).to receive(:last_block).with(event_type: "collector:#{subscription.handler_key}")
      end

      context 'when no previous status exists' do
        before do
          allow(Onchain::EventListenerStatus).to receive(:last_block).and_return("earliest")
        end

        it 'returns subscription start_block' do
          result = collector.send(:resolve_from_block, subscription)
          expect(result).to eq(subscription.start_block)
        end
      end

      context 'when previous status exists' do
        before do
          allow(Onchain::EventListenerStatus).to receive(:last_block).and_return("950")
        end

        it 'returns max of last status and start_block' do
          subscription.update!(start_block: 900)
          result = collector.send(:resolve_from_block, subscription)
          expect(result).to eq(950)
        end
      end

      context 'when start_block is newer than last status' do
        before do
          allow(Onchain::EventListenerStatus).to receive(:last_block).and_return("900")
        end

        it 'returns start_block' do
          subscription.update!(start_block: 950)
          result = collector.send(:resolve_from_block, subscription)
          expect(result).to eq(950)
        end
      end
    end

    describe '#normalize_from_block' do
      let(:latest_block) { 21 }

      it 'keeps checkpoint when it is not ahead of latest block' do
        expect(
          collector.send(:normalize_from_block, subscription, 20, latest_block)
        ).to eq(20)
      end

      it 'rewinds checkpoint to subscription start_block when chain is rolled back' do
        subscription.update!(start_block: 0)

        expect(Onchain::EventListenerStatus).to receive(:update_status).with(
          "collector:#{subscription.handler_key}",
          0,
          event_type: "collector:#{subscription.handler_key}"
        )

        expect(
          collector.send(:normalize_from_block, subscription, 73, latest_block)
        ).to eq(0)
      end
    end

    describe '#fetch_latest_block' do
      let(:election_service) { collector.instance_variable_get(:@election_service) }
      let(:mock_response) { { "result" => "0x3E8" } } # 1000 in hex

      before do
        allow(election_service).to receive(:with_leader).and_yield
        allow(collector).to receive(:perform_request).and_return(mock_response)
      end

      it 'returns decimal block number' do
        result = collector.send(:fetch_latest_block)
        expect(result).to eq(1000)
      end

      context 'when response has no result' do
        let(:mock_response) { { "error" => "No result" } }

        it 'returns nil' do
          result = collector.send(:fetch_latest_block)
          expect(result).to be_nil
        end
      end

      context 'when exception occurs' do
        before do
          allow(election_service).to receive(:with_leader).and_raise(StandardError.new('RPC Error'))
        end

        it 'logs error and returns nil' do
          expect(Rails.logger).to receive(:error).with(/获取最新区块失败/)
          result = collector.send(:fetch_latest_block)
          expect(result).to be_nil
        end
      end
    end

    describe '#fetch_logs' do
      let(:election_service) { collector.instance_variable_get(:@election_service) }
      let(:mock_logs) { [{ "address" => "0x123", "topics" => [], "data" => "0xabc" }] }
      let(:mock_response) { { "result" => mock_logs } }

      before do
        subscription.update!(addresses: ["0x123"], topics: ["0xabc"])
        allow(election_service).to receive(:with_leader).and_yield
        allow(collector).to receive(:perform_request).and_return(mock_response)
      end

      it 'fetches logs with correct parameters' do
        expected_params = [{
          fromBlock: "0x3e8", # 1000
          toBlock: "0x3e9",   # 1001
          address: ["0x123"],
          topics: ["0xabc"]
        }]

        expect(collector).to receive(:perform_request).with("eth_getLogs", expected_params)
        result = collector.send(:fetch_logs, subscription, 1000, 1001)
        expect(result).to eq(mock_logs)
      end

      context 'when RPC returns error' do
        let(:mock_response) { { "error" => { "code" => -32000, "message" => "Invalid range" } } }

        it 'raises RuntimeError' do
          expect {
            collector.send(:fetch_logs, subscription, 1000, 1001)
          }.to raise_error(RuntimeError)
        end
      end

      context 'when result is nil' do
        let(:mock_response) { { "result" => nil } }

        it 'returns empty array' do
          result = collector.send(:fetch_logs, subscription, 1000, 1001)
          expect(result).to eq([])
        end
      end
    end

    describe '#perform_request' do
      let(:rate_limiter) { double('rate_limiter') }
      let(:connection) { collector.instance_variable_get(:@connection) }
      let(:mock_response) { double('response', body: { "result" => "success" }) }
      let(:request) { double('request', headers: {}) }

      before do
        allow(described_class).to receive(:rate_limiter).and_return(rate_limiter)
        allow(rate_limiter).to receive(:acquire)
        allow(connection).to receive(:post).and_yield(request).and_return(mock_response)
        allow(request).to receive(:body=)
      end

      it 'acquires rate limit token before request' do
        expect(rate_limiter).to receive(:acquire)
        collector.send(:perform_request, "eth_blockNumber", [])
      end

      it 'sends properly formatted JSON-RPC request' do
        expect(connection).to receive(:post) do |&block|
          block.call(request)
        end.and_return(mock_response)
        expect(request).to receive(:body=).with(include('"method":"eth_blockNumber"'))

        collector.send(:perform_request, "eth_blockNumber", [])
      end

      it 'returns response body' do
        result = collector.send(:perform_request, "eth_blockNumber", [])
        expect(result).to eq(mock_response.body)
      end
    end

    describe '#persist_logs' do
      let(:logs) do
        [
          {
            "address" => "0x1234567890123456789012345678901234567890",
            "topics" => ["0xabcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890"],
            "data" => "0x0000000000000000000000000000000000000000000000000000000000000001",
            "blockNumber" => "0x3E8",
            "blockHash" => "0x1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef",
            "transactionHash" => "0xabcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            "logIndex" => "0x1",
            "transactionIndex" => "0x0",
            "timeStamp" => "0x61A8A8B0"
          }
        ]
      end

      before do
        allow(subscription).to receive(:event_name_for).and_return("TestEvent")
        consumption_job = instance_double(Jobs::Indexer::EventConsumptionJob, perform: true)
        allow(Jobs::Indexer::EventConsumptionJob).to receive(:new).and_return(consumption_job)
      end

      it 'creates RawLog records' do
        expect {
          collector.send(:persist_logs, subscription, logs)
        }.to change(Onchain::RawLog, :count).by(1)
      end

      it 'creates EventConsumption records' do
        expect {
          collector.send(:persist_logs, subscription, logs)
        }.to change(Onchain::LogConsumption, :count).by(1)
      end

      it 'dispatches EventConsumptionJob synchronously' do
        consumption_job = instance_double(Jobs::Indexer::EventConsumptionJob)
        expect(Jobs::Indexer::EventConsumptionJob).to receive(:new).and_return(consumption_job)
        expect(consumption_job).to receive(:perform).with(kind_of(Integer))
        collector.send(:persist_logs, subscription, logs)
      end

      it 'handles duplicate records gracefully' do
        # Create existing record with same address/blockNumber/etc
        existing_log = create(:onchain_raw_log, address: logs.first["address"])

        expect {
          collector.send(:persist_logs, subscription, logs)
        }.not_to raise_error
      end

      it 'logs errors when record creation fails' do
        allow(Onchain::RawLog).to receive(:create!).and_raise(StandardError.new('DB Error'))
        expect(Rails.logger).to receive(:error).with(/写入 raw_log 失败/)
        collector.send(:persist_logs, subscription, logs)
      end
    end

    describe '#hex_to_i' do
      it 'converts hex string to integer' do
        expect(collector.send(:hex_to_i, "0x3E8")).to eq(1000)
        expect(collector.send(:hex_to_i, "0x10")).to eq(16)
      end

      it 'handles string without 0x prefix' do
        expect(collector.send(:hex_to_i, "3E8")).to eq(1000)
      end

      it 'returns nil for nil input' do
        expect(collector.send(:hex_to_i, nil)).to be_nil
      end

      it 'handles integer input' do
        expect(collector.send(:hex_to_i, 1000)).to eq(1000)
      end
    end

    describe '#cleanup_retention' do
      let(:old_raw_log) { create(:onchain_raw_log, created_at: 10.days.ago) }
      let(:new_raw_log) { create(:onchain_raw_log, created_at: 1.day.ago) }

      before do
        old_raw_log.log_consumptions.create!(handler_key: 'test', status: 'success')
        new_raw_log.log_consumptions.create!(handler_key: 'test', status: 'pending')
      end

      context 'when retention is configured' do
        before do
          allow(Rails.application.config.x).to receive(:log_collector).and_return(double('config', retention_days: 7))
        end

        it 'keeps logs with incomplete consumptions' do
          old_raw_log.log_consumptions.update_all(status: 'pending')

          expect {
            collector.send(:cleanup_retention)
          }.not_to change(Onchain::RawLog, :count)
        end

        it 'deletes old logs with only successful consumptions' do
          expect {
            collector.send(:cleanup_retention)
          }.to change(Onchain::RawLog, :count).by(-1)
        end
      end

      context 'when retention is not configured' do
        before do
          allow(Rails.application.config.x).to receive(:log_collector).and_return(double('config', retention_days: nil))
        end

        it 'does nothing' do
          expect {
            collector.send(:cleanup_retention)
          }.not_to change(Onchain::RawLog, :count)
        end
      end

      context 'when retention is zero or negative' do
        before do
          allow(Rails.application.config.x).to receive(:log_collector).and_return(double('config', retention_days: 0))
        end

        it 'does nothing' do
          expect {
            collector.send(:cleanup_retention)
          }.not_to change(Onchain::RawLog, :count)
        end
      end
    end
  end
end
