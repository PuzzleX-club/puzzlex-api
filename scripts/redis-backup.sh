#!/bin/bash

# Redis备份脚本 - Pre-Prod环境
# 定期备份Redis数据，支持手动和自动备份

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 配置
NAMESPACE="puzzlex"
BACKUP_DIR="${BACKUP_DIR:-$(pwd)/backups}"
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

# 创建备份目录
create_backup_dir() {
    if [[ ! -d "$BACKUP_DIR" ]]; then
        mkdir -p "$BACKUP_DIR"
        log_success "✅ 创建备份目录: $BACKUP_DIR"
    fi
}

# 获取Redis Pod名称
get_redis_pod() {
    REDIS_POD=$(kubectl get pods -n "$NAMESPACE" -l app=redis-master -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

    if [[ -z "$REDIS_POD" ]]; then
        log_error "❌ 找不到Redis Pod，请检查Redis是否正常运行"
        exit 1
    fi

    echo "$REDIS_POD"
}

# 检查Redis连接
check_redis_connection() {
    local pod_name=$1
    log_info "🔍 检查Redis连接..."

    if ! kubectl exec -n "$NAMESPACE" "$pod_name" -- redis-cli ping | grep -q "PONG"; then
        log_error "❌ Redis连接失败"
        exit 1
    fi

    log_success "✅ Redis连接正常"
}

# 执行Redis备份
backup_redis() {
    local pod_name=$1
    local timestamp=$(date +"%Y%m%d-%H%M%S")
    local backup_file="redis-backup-${timestamp}.rdb"
    local backup_path="$BACKUP_DIR/$backup_file"

    log_info "📦 开始备份Redis数据..."

    # 触发后台保存
    log_info "触发BGSAVE命令..."
    kubectl exec -n "$NAMESPACE" "$pod_name" -- redis-cli BGSAVE

    # 等待备份完成
    log_info "等待备份完成..."
    while true; do
        local lastsave_result=$(kubectl exec -n "$NAMESPACE" "$pod_name" -- redis-cli LASTSAVE)
        local current_time=$(date +%s)
        local time_diff=$((current_time - lastsave_result))

        if [[ $time_diff -lt 10 ]]; then
            log_success "✅ 备份完成"
            break
        fi

        log_info "备份进行中... (${time_diff}秒前开始)"
        sleep 5
    done

    # 复制备份文件
    log_info "复制备份文件到本地..."
    kubectl exec -n "$NAMESPACE" "$pod_name" -- cat /data/dump.rdb > "$backup_path"

    if [[ -f "$backup_path" && -s "$backup_path" ]]; then
        local backup_size=$(du -h "$backup_path" | cut -f1)
        log_success "✅ 备份成功: $backup_path (大小: $backup_size)"
        echo "$backup_path"
    else
        log_error "❌ 备份文件创建失败"
        exit 1
    fi
}

# 压缩备份文件
compress_backup() {
    local backup_file=$1
    log_info "🗜️ 压缩备份文件..."

    if command -v gzip &> /dev/null; then
        gzip "$backup_file"
        local compressed_file="${backup_file}.gz"
        local compressed_size=$(du -h "$compressed_file" | cut -f1)
        log_success "✅ 压缩完成: $compressed_file (大小: $compressed_size)"
        echo "$compressed_file"
    else
        log_warning "⚠️ gzip未安装，跳过压缩"
        echo "$backup_file"
    fi
}

# 清理旧备份
cleanup_old_backups() {
    local keep_days=${1:-7}
    log_info "🧹 清理${keep_days}天前的旧备份..."

    local deleted_count=0
    while IFS= read -r -d '' file; do
        rm -f "$file"
        log_info "删除旧备份: $(basename "$file")"
        ((deleted_count++))
    done < <(find "$BACKUP_DIR" -name "redis-backup-*.rdb*" -type f -mtime +$keep_days -print0 2>/dev/null)

    if [[ $deleted_count -gt 0 ]]; then
        log_success "✅ 清理完成，删除了${deleted_count}个旧备份文件"
    else
        log_info "ℹ️ 没有需要清理的旧备份文件"
    fi
}

# 验证备份完整性
verify_backup() {
    local backup_file=$1
    log_info "🔍 验证备份完整性..."

    if [[ "$backup_file" == *.gz ]]; then
        # 验证压缩文件
        if gzip -t "$backup_file" 2>/dev/null; then
            log_success "✅ 备份文件完整性验证通过"
        else
            log_error "❌ 备份文件损坏"
            exit 1
        fi
    else
        # 验证RDB文件头部
        if file "$backup_file" | grep -q "Redis"; then
            log_success "✅ 备份文件格式正确"
        else
            log_error "❌ 备份文件格式不正确"
            exit 1
        fi
    fi
}

# 显示备份信息
show_backup_info() {
    local backup_file=$1
    log_info "📋 备份信息:"
    echo "  文件路径: $backup_file"
    echo "  文件大小: $(du -h "$backup_file" | cut -f1)"
    echo "  创建时间: $(stat -c "%y" "$backup_file")"
    echo "  备份目录: $BACKUP_DIR"
    echo ""
}

# 列出所有备份
list_backups() {
    log_info "📚 现有备份文件:"

    if [[ -d "$BACKUP_DIR" ]] && [[ -n "$(find "$BACKUP_DIR" -name "redis-backup-*" -type f 2>/dev/null)" ]]; then
        find "$BACKUP_DIR" -name "redis-backup-*" -type f -exec ls -lh {} \; | while read -r line; do
            local file=$(echo "$line" | awk '{print $9}')
            local size=$(echo "$line" | awk '{print $5}')
            local date=$(echo "$line" | awk '{print $6, $7, $8}')
            echo "  📄 $(basename "$file") ($size) - $date"
        done
    else
        log_info "ℹ️ 没有找到备份文件"
    fi
    echo ""
}

# 恢复Redis数据
restore_redis() {
    local backup_file=$1

    if [[ ! -f "$backup_file" ]]; then
        log_error "❌ 备份文件不存在: $backup_file"
        exit 1
    fi

    log_warning "⚠️ 恢复操作将覆盖当前Redis数据，确认继续？(y/N)"
    read -r confirmation

    if [[ "$confirmation" != "y" && "$confirmation" != "Y" ]]; then
        log_info "❌ 恢复操作已取消"
        exit 0
    fi

    local pod_name=$(get_redis_pod)

    log_info "🔄 开始恢复Redis数据..."

    # 如果是压缩文件，先解压
    if [[ "$backup_file" == *.gz ]]; then
        gunzip -c "$backup_file" > /tmp/redis-restore.rdb
        backup_file="/tmp/redis-restore.rdb"
    fi

    # 停止Redis写入（可选）
    log_info "停止Redis写入..."
    kubectl exec -n "$NAMESPACE" "$pod_name" -- redis-cli CLIENT PAUSE 5000

    # 复制备份文件到Pod
    kubectl cp "$backup_file" "$NAMESPACE/$pod_name:/data/dump.rdb"

    # 重启Redis Pod
    log_info "重启Redis Pod..."
    kubectl delete pod "$pod_name" -n "$NAMESPACE"

    log_success "✅ 恢复完成，Redis Pod正在重启..."
}

# 显示帮助信息
show_help() {
    echo "Redis备份脚本 - Pre-Prod环境"
    echo ""
    echo "使用方法:"
    echo "  $0 [选项] [参数]"
    echo ""
    echo "选项:"
    echo "  -h, --help              显示此帮助信息"
    echo "  -b, --backup            执行备份（默认）"
    echo "  -l, --list              列出所有备份文件"
    echo "  -r, --restore <file>    从备份文件恢复"
    echo "  -c, --cleanup <days>    清理指定天数前的备份（默认7天）"
    echo "  -v, --verify <file>     验证备份文件完整性"
    echo ""
    echo "示例:"
    echo "  $0                      # 执行备份"
    echo "  $0 -l                   # 列出备份文件"
    echo "  $0 -r backup-20231201-120000.rdb.gz  # 恢复数据"
    echo "  $0 -c 3                 # 清理3天前的备份"
    echo ""
    echo "环境变量:"
    echo "  BACKUP_DIR              备份目录（默认: ./backups）"
    echo ""
}

# 主函数
main() {
    # 检查参数
    case "$1" in
        -h|--help)
            show_help
            exit 0
            ;;
        -l|--list)
            list_backups
            exit 0
            ;;
        -r|--restore)
            if [[ -z "$2" ]]; then
                log_error "❌ 请指定备份文件"
                show_help
                exit 1
            fi
            restore_redis "$2"
            exit 0
            ;;
        -c|--cleanup)
            local days=${2:-7}
            cleanup_old_backups "$days"
            exit 0
            ;;
        -v|--verify)
            if [[ -z "$2" ]]; then
                log_error "❌ 请指定备份文件"
                show_help
                exit 1
            fi
            verify_backup "$2"
            exit 0
            ;;
        -b|--backup|"")
            # 执行备份流程
            ;;
        *)
            log_error "❌ 未知选项: $1"
            show_help
            exit 1
            ;;
    esac

    # 切换到backend目录
    cd "$SCRIPT_DIR/.."

    # 执行备份流程
    create_backup_dir
    REDIS_POD=$(get_redis_pod)
    check_redis_connection "$REDIS_POD"

    backup_file=$(backup_redis "$REDIS_POD")
    compressed_file=$(compress_backup "$backup_file")

    # 如果备份被压缩，删除原始文件
    if [[ "$compressed_file" != "$backup_file" ]]; then
        rm -f "$backup_file"
    fi

    verify_backup "$compressed_file"
    show_backup_info "$compressed_file"

    # 清理旧备份
    cleanup_old_backups 7

    log_success "🎉 Redis备份流程完成！"
}

# 错误处理
trap 'log_error "❌ 备份过程中发生错误"; exit 1' ERR

# 运行主函数
main "$@"