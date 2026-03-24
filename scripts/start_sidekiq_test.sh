#!/bin/bash
# 启动Sidekiq测试环境

echo "🚀 启动Sidekiq测试环境..."
echo "================================"

# 确保在backend目录
cd "$(dirname "$0")/.." || exit 1

# 设置测试环境变量
export RAILS_ENV=test
export RACK_ENV=test

# 加载测试环境配置文件（优先级最高，会覆盖下面的设置）
if [ -f .env.test ]; then
    echo "📋 加载测试环境配置 (.env.test)..."
    export $(cat .env.test | grep -v '^#' | xargs)
else
    # 如果没有.env.test，使用默认值
    export ASYNC_JOBS=true
    export REDIS_URL=redis://localhost:6381/0
fi

echo "📍 当前目录: $(pwd)"
echo "🌍 Rails环境: $RAILS_ENV"
echo "🔄 异步模式: $ASYNC_JOBS"
echo "🔗 区块链RPC: $BLOCKCHAIN_RPC_URL"
echo "📜 Seaport合约: $SEAPORT_CONTRACT_ADDRESS"

# 检查Redis连接（测试环境使用6381端口）
echo "🔍 检查Redis连接 (端口6381)..."
if redis-cli -p 6381 ping > /dev/null 2>&1; then
    echo "✓ Redis测试环境连接正常 (localhost:6381)"
else
    echo "❌ Redis测试环境未运行，请先启动Redis (端口6381)"
    exit 1
fi

# 检查测试数据库
echo "🔍 检查测试数据库..."
bundle exec rails db:migrate:status RAILS_ENV=test > /dev/null 2>&1
if [ $? -eq 0 ]; then
    echo "✓ 测试数据库正常"
else
    echo "⚠️  准备测试数据库..."
    bundle exec rails db:create RAILS_ENV=test 2>/dev/null || true
    bundle exec rails db:migrate RAILS_ENV=test
fi

# 清理测试日志
echo "🧹 清理Sidekiq日志..."
> log/sidekiq_test.log

# 启动Sidekiq
echo "🚀 启动Sidekiq (测试环境)..."
echo "📝 日志文件: log/sidekiq_test.log"
echo ""
echo "队列配置:"
echo "  - default"
echo "  - mailers"
echo "  - critical"
echo ""
echo "🛑 按 Ctrl+C 停止Sidekiq"
echo "================================"

# 启动Sidekiq，输出到日志文件
# 使用配置文件中的队列配置
RAILS_ENV=test ASYNC_JOBS=true REDIS_URL=redis://localhost:6381/0 bundle exec sidekiq -C config/sidekiq.yml -e test >> log/sidekiq_test.log 2>&1 &

# 保存PID
SIDEKIQ_PID=$!
echo $SIDEKIQ_PID > .sidekiq_test.pid

echo "✅ Sidekiq已在后台启动 (PID: $SIDEKIQ_PID)"
echo "📝 查看日志: tail -f log/sidekiq_test.log"
echo ""
echo "🛑 停止Sidekiq: kill $(cat .sidekiq_test.pid)"