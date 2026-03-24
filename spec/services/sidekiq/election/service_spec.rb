# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Sidekiq::Election::Service, type: :service, redis: :real do
  let(:instance_id) { 'sidekiq-test-1' }
  let(:service) { described_class.new(instance_id) }
  let(:redis) { Redis.current }

  before do
    described_class.stop
    described_class.instance_variable_set(:@instance, nil)
    described_class.instance_variable_set(:@running, false)

    # 清理Redis中的测试数据
    redis.del(described_class::LOCK_KEY)
    redis.del(described_class::TOKEN_KEY)
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

    # Mock Sidekiq::Cluster::InstanceRegistry
    allow(Sidekiq::Cluster::InstanceRegistry).to receive(:new).and_return(double(instance_id: instance_id))
    allow(described_class).to receive(:enabled?).and_return(true)
  end

  after do
    # 清理测试数据
    service.stop if service.is_leader
    described_class.stop
    redis.del(described_class::LOCK_KEY)
    redis.del(described_class::TOKEN_KEY)
    redis.del('sidekiq:leader:changes')
    redis.del('sidekiq:leader:last_time')
  end

  describe '.start' do
    it '应该启动选举服务' do
      described_class.start
      expect(described_class.instance).to be_present
    end

    it '只启动一次' do
      described_class.start
      expect { described_class.start }.not_to change { described_class.instance }
    end
  end

  describe '.stop' do
    it '应该停止选举服务' do
      described_class.start
      described_class.stop
      expect(described_class.instance_variable_get(:@instance)).to be_nil
    end
  end

  describe '.leader?' do
    it '检查是否为leader' do
      redis.set(described_class::LOCK_KEY, "1:#{instance_id}:1234567890")
      expect(described_class.leader?).to be true

      redis.set(described_class::LOCK_KEY, "1:other-instance:1234567890")
      expect(described_class.leader?).to be false
    end
  end

  describe '.with_leader' do
    it 'leader实例执行块' do
      allow(described_class).to receive(:leader?).and_return(true)
      executed = false

      result = described_class.with_leader do
        executed = true
        'executed'
      end

      expect(executed).to be true
      expect(result).to eq 'executed'
    end

    it '非leader实例跳过执行' do
      allow(described_class).to receive(:leader?).and_return(false)
      executed = false

      result = described_class.with_leader do
        executed = true
        'executed'
      end

      expect(executed).to be false
      expect(result).to be_nil
    end
  end

  describe '#initialize' do
    it '初始化服务实例' do
      expect(service.instance_id).to eq instance_id
      expect(service.token).to be_nil
      expect(service.is_leader).to be false
    end
  end

  describe '#start' do
    it '成功获取锁时成为leader' do
      expect(service.start).to be true
      expect(service.is_leader).to be true
      expect(service.token).to be_present
      expect(service.lock_acquired_at).to be_present
    end

    it '生成fencing token' do
      service.start
      expect(service.token).to match(/^\d+$/)
    end

    it '锁已存在时获取失败' do
      # 先创建另一个实例获取锁
      other_service = described_class.new('sidekiq-test-2')
      other_service.start

      expect(service.start).to be false
      expect(service.is_leader).to be false
    end

    it '记录leader变更' do
      expect(Sidekiq::Election::Monitoring::MetricsCollector)
        .to receive(:record_leader_change).with(instance_id, kind_of(String))

      service.start
    end
  end

  describe '#stop' do
    before { service.start }

    it '释放锁并降级' do
      expect(service.is_leader).to be true

      service.stop

      expect(service.is_leader).to be false
      expect(redis.get(described_class::LOCK_KEY)).to be_nil
    end

    it '不是leader时也能正常停止' do
      service.instance_variable_set(:@is_leader, false)

      expect { service.stop }.not_to raise_error
    end
  end

  describe '#renew_lock' do
    before { service.start }

    it 'leader成功续约' do
      expect(service.send(:renew_lock)).to be true
    end

    it '非leader续约失败' do
      # 手动清理锁值，模拟失去leader
      service.instance_variable_set(:@lock_value, 'invalid:value')

      expect(service.send(:renew_lock)).to be false
    end
  end

  describe '心跳机制' do
    it '成功续约重置失败计数' do
      allow(service).to receive(:start_heartbeat_thread)
      service.start
      service.instance_variable_set(:@consecutive_failures, 2)

      allow(service).to receive(:start_heartbeat_thread).and_call_original
      allow(service).to receive(:perform_heartbeat) do
        service.instance_variable_set(:@is_leader, false)
        true
      end
      allow(service).to receive(:sleep)
      allow(Thread).to receive(:new).and_yield.and_return(instance_double(Thread, kill: true))

      # 模拟心跳线程执行一次
      service.send(:start_heartbeat_thread)

      expect(service.instance_variable_get(:@consecutive_failures)).to eq 0
    end

    it '连续失败达到阈值时降级' do
      allow(service).to receive(:start_heartbeat_thread)
      service.start
      service.instance_variable_set(:@consecutive_failures, described_class.max_consecutive_failures)
      allow(service).to receive(:stop_heartbeat_thread)
      expect(service).to receive(:send_alert).with('leader_heartbeat_failure')

      service.send(:handle_heartbeat_failure)

      expect(service.is_leader).to be false
    end
  end

  describe 'Lua脚本' do
    describe 'acquire_lock' do
      before do
        service.instance_variable_set(:@token, service.send(:generate_fencing_token))
      end

      it '锁不存在时获取成功' do
        result = service.send(:acquire_lock)

        expect(result).to be true
        expect(service.instance_variable_get(:@lock_value)).to match(/^\d+:#{instance_id}:\d+$/)
      end

      it '锁已过期时重新获取' do
        # 创建一个已过期的锁
        redis.psetex(described_class::LOCK_KEY, 100, 'old_token:old_instance:0')

        # 等待过期
        sleep 0.2

        result = service.send(:acquire_lock)

        expect(result).to be true
      end

      it '锁被持有时获取失败' do
        # 创建一个有效的锁
        redis.setex(described_class::LOCK_KEY, 60, 'other_token:other_instance:1234567890')

        result = service.send(:acquire_lock)

        expect(result).to be false
      end
    end

    describe 'renew_lock' do
      before do
        service.start
      end

      it '持有者成功续约' do
        # 设置锁值
        lock_value = service.instance_variable_get(:@lock_value)

        result = service.send(:renew_lock)

        expect(result).to be true
      end

      it '非持有者续约失败' do
        service.instance_variable_set(:@lock_value, 'wrong_token:wrong_instance:0')

        result = service.send(:renew_lock)

        expect(result).to be false
      end
    end

    describe 'release_lock' do
      before do
        service.start
      end

      it '持有者成功释放' do
        result = service.send(:release_lock)

        expect(result).to be true
        expect(redis.get(described_class::LOCK_KEY)).to be_nil
      end

      it '非持有者释放失败' do
        # 修改锁值
        redis.set(described_class::LOCK_KEY, 'other_token:other_instance:0')

        result = service.send(:release_lock)

        expect(result).to be false
        expect(redis.get(described_class::LOCK_KEY)).to eq 'other_token:other_instance:0'
      end
    end
  end

  describe '并发测试' do
    it '多个实例只有一个成为leader' do
      services = Array.new(5) do |i|
        described_class.new("sidekiq-test-#{i}")
      end

      # 并发启动
      results = services.map(&:start)
      leader_count = results.count(true)

      expect(leader_count).to eq 1

      # 清理
      services.each(&:stop)
    end

    it 'leader停止后其他实例成为新leader' do
      service1 = described_class.new('sidekiq-1')
      service2 = described_class.new('sidekiq-2')

      service1.start
      expect(service1.is_leader).to be true

      service2.start
      expect(service2.is_leader).to be false

      # 停止第一个leader
      service1.stop
      expect(service1.is_leader).to be false

      # 第二个服务尝试获取锁
      expect(service2.send(:acquire_lock)).to be true

      service2.stop
    end
  end
end
