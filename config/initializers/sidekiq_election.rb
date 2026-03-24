# frozen_string_literal: true

# Sidekiq Leader选举服务初始化器
#
# 注意：选举服务的实际启动已移至 config/initializers/sidekiq.rb 的 on(:startup) 钩子中
# 这样可以确保在 Sidekiq 服务器完全启动后才启动选举服务
#
# 配置项通过环境变量设置（云原生 12-Factors）：
# - SIDEKIQ_ELECTION_ENABLED: 是否启用选举服务 (true/false)
# - SIDEKIQ_ELECTION_HEARTBEAT_INTERVAL: 心跳间隔秒数 (默认10)
# - SIDEKIQ_ELECTION_HEARTBEAT_JITTER: 心跳抖动秒数 (默认2)
# - SIDEKIQ_ELECTION_TTL_SECONDS: 锁TTL秒数 (默认35)
# - SIDEKIQ_ELECTION_MAX_FAILURES: 最大连续失败次数 (默认3)
# - SIDEKIQ_ELECTION_MONITORING_ENABLED: 是否启用监控 (true/false)
#
# 选举状态可通过以下方式获取：
#   Sidekiq::Election::Service.leader?      # 当前实例是否为leader
#   Sidekiq::Election::Service.status       # 完整状态信息
#   Sidekiq::Election::Service.fencing_token # 当前fencing token
#
# Leader独占操作：
#   Sidekiq::Election::Service.with_leader do
#     # 仅在leader上执行的代码
#   end
