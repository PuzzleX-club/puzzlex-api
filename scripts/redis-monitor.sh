#!/bin/bash

# Redis监控脚本 - Pre-Prod环境
# 监控Redis性能、内存使用和索引器相关状态

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 配置
NAMESPACE="puzzlex"
REDIS_POD_PREFIX="redis-master"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 日志函数
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# 检查Redis Pod状态
check_redis_status() {
    log_info "🔍 检查Redis Pod状态..."

    REDIS_POD=$(kubectl get pods -n "$NAMESPACE" -l app=redis-master -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

    if [[ -z "$REDIS_POD" ]]; then
        log_error "❌ 找不到Redis Pod，请检查Redis是否正常运行"
        exit 1
    fi

    if ! kubectl get pod "$REDIS_POD" -n "$NAMESPACE" | grep -q "Running"; then
        log_error "❌ Redis Pod未运行，状态: $(kubectl get pod "$REDIS_POD" -n "$NAMESPACE" -o jsonpath='{.status.phase}')"
        exit 1
    fi

    log_success "✅ Redis Pod状态正常: $REDIS_POD"
    echo "$REDIS_POD"
}

# 获取Redis基本信息
get_redis_info() {
    local pod_name=$1
    log_info "📊 获取Redis基本信息..."

    echo ""
    echo "=== Redis基本信息 ==="

    # 服务器信息
    local redis_version=$(kubectl exec -n "$NAMESPACE" "$pod_name" -- redis-cli info server | grep "redis_version" | cut -d: -f2 | tr -d '\r')
    local uptime_in_seconds=$(kubectl exec -n "$NAMESPACE" "$pod_name" -- redis-cli info server | grep "uptime_in_seconds" | cut -d: -f2 | tr -d '\r')
    local uptime_days=$((uptime_in_seconds / 86400))

    echo "🔧 版本: $redis_version"
    echo "⏰ 运行时间: ${uptime_days}天 ($uptime_in_seconds秒)"
    echo ""
}

# 获取Redis内存信息
get_memory_info() {
    local pod_name=$1
    log_info "💾 获取Redis内存信息..."

    echo "=== 内存使用情况 ==="

    local used_memory_human=$(kubectl exec -n "$NAMESPACE" "$pod_name" -- redis-cli info memory | grep "used_memory_human" | cut -d: -f2 | tr -d '\r')
    local used_memory_peak_human=$(kubectl exec -n "$NAMESPACE" "$pod_name" -- redis-cli info memory | grep "used_memory_peak_human" | cut -d: -f2 | tr -d '\r')
    local maxmemory_human=$(kubectl exec -n "$NAMESPACE" "$pod_name" -- redis-cli config get maxmemory | tail -1)

    echo "📈 当前内存: $used_memory_human"
    echo "🔝 峰值内存: $used_memory_peak_human"
    echo "⚙️ 最大内存: ${maxmemory_human}B"

    # 计算内存使用率
    local used_memory_bytes=$(kubectl exec -n "$NAMESPACE" "$pod_name" -- redis-cli info memory | grep "used_memory:" | cut -d: -f2 | tr -d '\r')
    local maxmemory_bytes=$(kubectl exec -n "$NAMESPACE" "$pod_name" -- redis-cli config get maxmemory | tail -1)

    if [[ "$maxmemory_bytes" != "0" ]]; then
        local usage_percent=$((used_memory_bytes * 100 / maxmemory_bytes))
        if (( usage_percent > 80 )); then
            log_warning "⚠️ 内存使用率较高: ${usage_percent}%"
        else
            log_success "✅ 内存使用率: ${usage_percent}%"
        fi
    fi
    echo ""
}

# 获取Keyspace信息
get_keyspace_info() {
    local pod_name=$1
    log_info "🔑 获取Keyspace信息..."

    echo "=== 数据库Keyspace ==="

    kubectl exec -n "$NAMESPACE" "$pod_name" -- redis-cli info keyspace | head -10
    echo ""

    # 检查索引器相关的key
    echo "=== 索引器相关Keys ==="
    local indexer_keys=$(kubectl exec -n "$NAMESPACE" "$pod_name" -- redis-cli keys "*indexer*" 2>/dev/null || echo "无索引器相关keys")
    local sidekiq_keys=$(kubectl exec -n "$NAMESPACE" "$pod_name" -- redis-cli keys "*sidekiq*" 2>/dev/null || echo "无Sidekiq相关keys")

    echo "🔍 索引器Keys数量: $(echo "$indexer_keys" | wc -w)"
    echo "⚙️ Sidekiq Keys数量: $(echo "$sidekiq_keys" | wc -w)"
    echo ""
}

# 获取客户端连接信息
get_client_info() {
    local pod_name=$1
    log_info "👥 获取客户端连接信息..."

    echo "=== 客户端连接 ==="

    local connected_clients=$(kubectl exec -n "$NAMESPACE" "$pod_name" -- redis-cli info clients | grep "connected_clients" | cut -d: -f2 | tr -d '\r')
    local blocked_clients=$(kubectl exec -n "$NAMESPACE" "$pod_name" -- redis-cli info clients | grep "blocked_clients" | cut -d: -f2 | tr -d '\r')

    echo "🔗 当前连接数: $connected_clients"
    echo "🚫 阻塞连接数: $blocked_clients"

    if (( connected_clients > 100 )); then
        log_warning "⚠️ 客户端连接数较多: $connected_clients"
    else
        log_success "✅ 客户端连接数正常: $connected_clients"
    fi
    echo ""
}

# 检查Sidekiq状态
check_sidekiq_status() {
    local pod_name=$1
    log_info "⚙️ 检查Sidekiq状态..."

    echo "=== Sidekiq队列状态 ==="

    # 获取Sidekiq队列信息
    local sidekiq_queues=$(kubectl exec -n "$NAMESPACE" "$pod_name" -- redis-cli smembers sidekiq:queues 2>/dev/null || echo "无Sidekiq队列")

    if [[ "$sidekiq_queues" != "无Sidekiq队列" ]]; then
        echo "📋 Sidekiq队列:"
        for queue in $sidekiq_queues; do
            local queue_size=$(kubectl exec -n "$NAMESPACE" "$pod_name" -- redis-cli llen "queue:$queue" 2>/dev/null || echo "0")
            echo "  - $queue: $queue_size 任务"
        done
    else
        log_warning "⚠️ 未找到Sidekiq队列"
    fi

    # 检查Sidekiq进程
    echo ""
    echo "=== Sidekiq进程 ==="
    local processes=$(kubectl exec -n "$NAMESPACE" "$pod_name" -- redis-cli scard sidekiq:processes 2>/dev/null || echo "0")
    echo "🔄 活跃Sidekiq进程数: $processes"

    if (( processes == 0 )); then
        log_warning "⚠️ 没有活跃的Sidekiq进程"
    else
        log_success "✅ Sidekiq进程运行正常"
    fi
    echo ""
}

# 检查索引器处理进度
check_indexer_progress() {
    log_info "🔍 检查索引器处理进度..."

    # 检查后端日志中的索引器状态
    echo "=== 索引器处理进度（最近5分钟） ==="

    local recent_logs=$(kubectl logs deployment/puzzlex-backend-sidekiq -n "$NAMESPACE" --since=5m 2>/dev/null || echo "")

    if echo "$recent_logs" | grep -q "索引器启用状态"; then
        echo "$recent_logs" | grep "索引器启用状态" | tail -1
    fi

    if echo "$recent_logs" | grep -q "订阅配置初始化完成"; then
        echo "$recent_logs" | grep "订阅配置初始化完成" | tail -1
    fi

    if echo "$recent_logs" | grep -q "LogCollector.*已启用"; then
        echo "$recent_logs" | grep "LogCollector.*已启用" | tail -2
    fi

    echo ""
}

# 性能优化建议
get_performance_recommendations() {
    log_info "💡 性能优化建议..."

    echo "=== 性能建议 ==="
    echo "🔧 建议的配置检查:"
    echo "  - maxmemory-policy: allkeys-lru (当前)"
    echo "  - save策略: 定期保存"
    echo "  - appendonly: AOF持久化已启用"
    echo ""

    echo "📊 监控建议:"
    echo "  - 定期检查内存使用率"
    echo "  - 监控Keys增长趋势"
    echo "  - 关注Sidekiq队列积压情况"
    echo ""
}

# 实时监控模式
real_time_monitor() {
    local pod_name=$1
    log_info "📺 启动实时监控模式... (Ctrl+C 退出)"

    while true; do
        clear
        echo "🔍 Pre-Prod Redis实时监控 - $(date)"
        echo "========================================"

        # 基本状态
        local memory=$(kubectl exec -n "$NAMESPACE" "$pod_name" -- redis-cli info memory | grep "used_memory_human" | cut -d: -f2 | tr -d '\r')
        local clients=$(kubectl exec -n "$NAMESPACE" "$pod_name" -- redis-cli info clients | grep "connected_clients" | cut -d: -f2 | tr -d '\r')
        local keyspace=$(kubectl exec -n "$NAMESPACE" "$pod_name" -- redis-cli dbsize 2>/dev/null || echo "0")

        echo "💾 内存使用: $memory"
        echo "👥 客户端连接: $clients"
        echo "🔑 Key总数: $keyspace"
        echo ""

        # Sidekiq队列状态
        echo "⚙️ Sidekiq队列状态:"
        local queues=$(kubectl exec -n "$NAMESPACE" "$pod_name" -- redis-cli smembers sidekiq:queues 2>/dev/null || echo "")
        for queue in $queues; do
            local size=$(kubectl exec -n "$NAMESPACE" "$pod_name" -- redis-cli llen "queue:$queue" 2>/dev/null || echo "0")
            echo "  - $queue: $size"
        done

        echo ""
        echo "⏰ 最后更新: $(date '+%H:%M:%S')"
        echo "按 Ctrl+C 退出监控"

        sleep 10
    done
}

# 显示帮助信息
show_help() {
    echo "Redis监控脚本 - Pre-Prod环境"
    echo ""
    echo "使用方法:"
    echo "  $0 [选项]"
    echo ""
    echo "选项:"
    echo "  -h, --help          显示此帮助信息"
    echo "  -s, --status        显示Redis基本状态"
    echo "  -m, --memory        显示内存使用详情"
    echo "  -k, --keyspace      显示Keyspace信息"
    echo "  -c, --clients       显示客户端连接信息"
    echo "  -i, --indexer       检查索引器状态"
    echo "  -r, --real-time     启动实时监控模式"
    echo "  -a, --all           显示所有信息（默认）"
    echo ""
    echo "示例:"
    echo "  $0                  # 显示所有信息"
    echo "  $0 -r               # 实时监控"
    echo "  $0 -m -i            # 显示内存和索引器状态"
    echo ""
}

# 主函数
main() {
    # 检查参数
    if [[ "$1" == "-h" || "$1" == "--help" ]]; then
        show_help
        exit 0
    fi

    # 切换到backend目录
    cd "$SCRIPT_DIR/.."

    # 获取Redis Pod名称
    REDIS_POD=$(check_redis_status)

    # 根据参数执行对应操作
    case "$1" in
        -s|--status)
            get_redis_info "$REDIS_POD"
            ;;
        -m|--memory)
            get_memory_info "$REDIS_POD"
            ;;
        -k|--keyspace)
            get_keyspace_info "$REDIS_POD"
            ;;
        -c|--clients)
            get_client_info "$REDIS_POD"
            ;;
        -i|--indexer)
            check_sidekiq_status "$REDIS_POD"
            check_indexer_progress
            ;;
        -r|--real-time)
            real_time_monitor "$REDIS_POD"
            ;;
        -a|--all|"")
            get_redis_info "$REDIS_POD"
            get_memory_info "$REDIS_POD"
            get_keyspace_info "$REDIS_POD"
            get_client_info "$REDIS_POD"
            check_sidekiq_status "$REDIS_POD"
            check_indexer_progress
            get_performance_recommendations
            ;;
        *)
            log_error "❌ 未知选项: $1"
            show_help
            exit 1
            ;;
    esac
}

# 错误处理
trap 'log_error "❌ 监控过程中发生错误"; exit 1' ERR

# 运行主函数
main "$@"