# frozen_string_literal: true

require 'rails_helper'

RSpec.describe "选举机制集成测试", type: :integration, integration: true, redis: :real do
  let(:redis) { Redis.current }

  before do
    Sidekiq::Election::Service.stop

    # 清理Redis
    redis.del('sidekiq:leader:lock')
    redis.del('sidekiq:leader:token')
    redis.del('sidekiq:leader:changes')
    redis.del('sidekiq:leader:last_time')

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
    collector.instance_variable_set(:@prometheus_available, false)
  end

  after do
    Sidekiq::Election::Service.stop
  end

  describe "并发抢锁测试" do
    it "多个实例只有一个成为leader" do
      services = []
      leaders = []

      # 创建多个服务实例
      5.times do |i|
        service = Sidekiq::Election::Service.new("instance-#{i}")
        services << service
      end

      # 并发尝试获取锁
      threads = services.map do |service|
        Thread.new do
          if service.start
            leaders << service.instance_id
          end
        end
      end

      # 等待所有线程完成
      threads.each(&:join)

      # 验证只有一个leader
      expect(leaders.size).to eq 1
      expect(services.select(&:is_leader).size).to eq 1

      # 清理
      services.each(&:stop)
    end

    it "fencing token单调递增" do
      first_service = Sidekiq::Election::Service.new("first")
      second_service = Sidekiq::Election::Service.new("second")

      # 第一个服务获取锁
      first_service.start
      first_token = first_service.token.to_i

      # 第一个服务释放锁
      first_service.stop

      # 等待一小段时间
      sleep 0.1

      # 第二个服务获取锁
      second_service.start
      second_token = second_service.token.to_i

      # 验证token递增
      expect(second_token).to be > first_token

      first_service.stop
      second_service.stop
    end
  end

  describe "故障转移测试" do
    it "leader失效后新leader产生" do
      service1 = Sidekiq::Election::Service.new("leader-1")
      service2 = Sidekiq::Election::Service.new("follower-1")

      # service1成为leader
      expect(service1.start).to be true
      expect(service1.is_leader).to be true

      # service2是follower
      expect(service2.start).to be false
      expect(service2.is_leader).to be false

      # 记录第一个leader的token
      first_token = service1.token

      # 模拟leader失效（停止服务）
      service1.stop

      # 等待TTL过期（35秒，但测试时可以手动清理）
      redis.del('sidekiq:leader:lock')

      # service2重新尝试成为新leader
      expect(service2.start).to be true
      expect(service2.is_leader).to be true

      # 验证新token更大
      expect(service2.token.to_i).to be > first_token.to_i

      service2.stop
    end
  end

  describe "心跳失败测试" do
    it "连续失败3次后降级" do
      service = Sidekiq::Election::Service.new("heartbeat-test")
      allow(service).to receive(:start_heartbeat_thread)
      service.start
      service.instance_variable_set(:@consecutive_failures, Sidekiq::Election::Service.max_consecutive_failures)
      allow(service).to receive(:stop_heartbeat_thread)
      allow(service).to receive(:send_alert)

      service.send(:handle_heartbeat_failure)

      # 验证已降级
      expect(service.is_leader).to be false

      service.stop
    end
  end

  describe "与EventPipeline集成测试" do
    it "非leader实例跳过RPC操作" do
      collector = Indexer::EventPipeline::Collector.new

      # Mock RPC请求
      allow(Sidekiq::Election::Service).to receive(:leader?).and_return(false)
      allow(Sidekiq::Election::Service).to receive(:status).and_return(token: 'leader-token')

      # 执行收集应该被跳过
      expect(collector).not_to receive(:fetch_latest_block)
      collector.run
    end

    it "leader实例正常执行RPC操作" do
      collector = Indexer::EventPipeline::Collector.new

      # Mock RPC请求
      allow(Sidekiq::Election::Service).to receive(:leader?).and_return(true)
      allow(Sidekiq::Election::Service).to receive(:with_leader).and_yield
      allow(collector).to receive(:fetch_latest_block).and_return(1000)
      allow_any_instance_of(Onchain::EventSubscription).to receive(:block_window).and_return(10)
      allow(collector).to receive(:fetch_logs).and_return([])
      allow(Onchain::EventListenerStatus).to receive(:update_status)
      allow(collector).to receive(:cleanup_retention)
      allow(collector).to receive(:resolve_from_block).and_return(0)
      allow(collector).to receive(:persist_logs)

      # 执行收集应该正常进行
      expect(collector).to receive(:fetch_latest_block)
      collector.run
    end
  end

  describe "Job集成测试" do
    it "EventCollectorJob非leader跳过执行" do
      allow(Sidekiq::Election::Service).to receive(:leader?).and_return(false)

      job = Jobs::Indexer::EventCollectorJob.new

      # 不应该执行收集
      expect(Indexer::EventPipeline::Collector).not_to receive(:new)
      job.perform
    end

    it "EventCollectorJob leader正常执行" do
      allow(Sidekiq::Election::Service).to receive(:leader?).and_return(true)
      collector = double("Collector")
      allow(Indexer::EventPipeline::Collector).to receive(:new).and_return(collector)

      job = Jobs::Indexer::EventCollectorJob.new

      # 应该执行收集
      expect(collector).to receive(:run)
      job.perform
    end
  end

  describe "数据一致性测试" do
    it "重复的锁获取被正确处理" do
      service = Sidekiq::Election::Service.new("consistency-test")

      # 第一次获取成功
      expect(service.start).to be true
      first_token = service.token

      # 第二次获取应该失败（已经在运行）
      service2 = Sidekiq::Election::Service.new("consistency-test")
      expect(service2.start).to be false

      # 停止后应该能重新获取
      service.stop
      service3 = Sidekiq::Election::Service.new("consistency-test")
      expect(service3.start).to be true
      expect(service3.token.to_i).to be > first_token.to_i

      service3.stop
    end

    it "锁值格式正确" do
      service = Sidekiq::Election::Service.new("format-test")
      service.start

      lock_value = redis.get('sidekiq:leader:lock')

      # 验证格式：token:instance_id:timestamp
      expect(lock_value).to match(/^\d+:format-test:\d+$/)

      service.stop
    end
  end

  describe "监控指标测试" do
    it "正确记录指标" do
      # Mock Prometheus指标
      mock_counter = double
      mock_gauge = double
      allow(mock_counter).to receive(:increment)
      allow(mock_gauge).to receive(:set)

      stub_const("Prometheus::Client", double('Prometheus::Client'))
      allow(Prometheus::Client).to receive(:registry).and_return(double(counter: mock_counter, gauge: mock_gauge))

      service = Sidekiq::Election::Service.new("metrics-test")

      # 启动应该记录指标
      expect(Sidekiq::Election::Monitoring::MetricsCollector)
        .to receive(:record_leader_change)

      service.start
      service.stop
    end
  end
end
