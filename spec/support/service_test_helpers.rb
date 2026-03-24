# frozen_string_literal: true

# 服务层测试辅助模块
# 提供统一的外部依赖 stub 方法，确保测试可以真正执行业务逻辑
module ServiceTestHelpers
  # Redis stub - 避免测试依赖真实 Redis
  def stub_redis
    redis = instance_double(Redis)
    allow(Redis).to receive(:current).and_return(redis)
    allow(redis).to receive_messages(
      get: nil,
      set: true,
      setex: true,
      setnx: true,
      del: true,
      keys: [],
      multi: nil,
      exec: [],
      pipelined: [],
      expire: true,
      ttl: -1,
      exists?: false,
      incr: 1,
      decr: 0,
      lpush: 1,
      rpush: 1,
      lpop: nil,
      rpop: nil,
      lrange: [],
      sadd: true,
      smembers: [],
      srem: true,
      zadd: true,
      zrange: [],
      zrem: true,
      hset: true,
      hget: nil,
      hgetall: {},
      hdel: true,
      publish: 0,
      mapped_hmset: true,
      hmset: true
    )
    redis
  end

  # ActionCable stub - 避免广播错误
  def stub_action_cable
    allow(ActionCable.server).to receive(:broadcast).and_return(true)
  end

  # Blockchain RPC stub
  def stub_blockchain_rpc
    # Eth gem client stub
    if defined?(Eth::Client)
      allow_any_instance_of(Eth::Client).to receive(:call).and_return('0x1')
      allow_any_instance_of(Eth::Client).to receive(:eth_get_balance).and_return(1_000_000)
      allow_any_instance_of(Eth::Client).to receive(:eth_block_number).and_return(12345678)
      allow_any_instance_of(Eth::Client).to receive(:eth_get_transaction_receipt).and_return({
        'status' => '0x1',
        'blockNumber' => '0xbc614e'
      })
    end

    # Web3 stub (if used)
    if defined?(Web3::Eth::Rpc)
      allow_any_instance_of(Web3::Eth::Rpc).to receive(:eth_block_number).and_return(12345678)
    end
  end

  # Sidekiq worker stub - 防止实际调度
  def stub_sidekiq_workers
    # 常用的 Worker 类
    workers = %w[
      Worker
      Jobs::Matching::Worker
      Jobs::Matching::DispatcherJob
      Jobs::Matching::RecoveryJob
      Jobs::Orders::DepthBroadcastJob
      Jobs::Merkle::GenerateMerkleTreeJob
    ]

    workers.each do |worker_class|
      klass = worker_class.safe_constantize
      next unless klass

      allow(klass).to receive(:perform_in).and_return(true)
      allow(klass).to receive(:perform_async).and_return(true)
      allow(klass).to receive(:perform_at).and_return(true)
    end
  end

  # HTTP 请求 stub
  def stub_http_requests
    if defined?(HTTParty)
      allow(HTTParty).to receive(:get).and_return(double(success?: true, body: '{}'))
      allow(HTTParty).to receive(:post).and_return(double(success?: true, body: '{}'))
    end
  end

  # 时间冻结辅助
  def freeze_time(time = Time.current)
    allow(Time).to receive(:current).and_return(time)
    allow(Time).to receive(:now).and_return(time)
  end

  # 创建带有完整关联的测试订单
  def create_order_with_items(traits = {})
    order = create(:trading_order, traits)
    create(:trading_order_item, :offer, order: order)
    create(:trading_order_item, :consideration, order: order)
    order.reload
  end

  # JSON 响应辅助
  def json_response
    JSON.parse(response.body)
  end
end

RSpec.configure do |config|
  # 在服务层测试中自动包含
  config.include ServiceTestHelpers, type: :service

  # 在模型测试中也包含（用于测试回调等）
  config.include ServiceTestHelpers, type: :model

  # 在请求测试中包含
  config.include ServiceTestHelpers, type: :request

  # 在 Channel 测试中包含
  config.include ServiceTestHelpers, type: :channel

  # 在 Job 测试中包含
  config.include ServiceTestHelpers, type: :job
end
