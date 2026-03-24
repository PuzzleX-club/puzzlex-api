#!/bin/bash
# Merkle树管理脚本 - 提供便捷的Merkle树操作命令
#
# 用法:
#   ./scripts/merkle_manager.sh [command] [options]
#
# 命令:
#   status              - 查看所有Merkle树的状态
#   generate [item_id]  - 生成Merkle树（默认所有NFT集合）
#   cleanup             - 清理过期的Merkle树数据（>10天）
#   verify [item_id]    - 验证Merkle树的完整性
#   roots               - 显示所有Merkle根
#   trigger-job         - 手动触发Sidekiq生成Job
#   help                - 显示帮助信息

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 获取当前Rails环境（默认development）
RAILS_ENV=${RAILS_ENV:-development}

# 脚本所在目录
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
BACKEND_DIR="$(dirname "$SCRIPT_DIR")"

# 切换到backend目录
cd "$BACKEND_DIR"

# 显示帮助信息
show_help() {
    echo "Merkle树管理脚本"
    echo ""
    echo "用法: $0 [command] [options]"
    echo ""
    echo "命令:"
    echo "  status              - 查看所有Merkle树的状态"
    echo "  generate [item_id]  - 生成Merkle树"
    echo "                        不带参数: 自动识别所有NFT集合并生成"
    echo "                        带item_id: 只生成指定item_id的树"
    echo "  cleanup             - 清理过期的Merkle树数据（>10天）"
    echo "  verify [item_id]    - 验证Merkle树的完整性"
    echo "  roots               - 显示所有Merkle根哈希"
    echo "  trigger-job         - 手动触发Sidekiq生成Job（异步）"
    echo "  help                - 显示此帮助信息"
    echo ""
    echo "环境变量:"
    echo "  RAILS_ENV           - Rails环境 (默认: development)"
    echo ""
    echo "示例:"
    echo "  $0 status                    # 查看状态"
    echo "  $0 generate                  # 为所有NFT集合生成"
    echo "  $0 generate 39               # 只为itemId 39生成"
    echo "  RAILS_ENV=test $0 generate   # 在测试环境生成"
    echo "  $0 trigger-job               # 触发Sidekiq异步生成"
    echo ""
    echo "ℹ️  自动化说明:"
    echo "  Sidekiq定时任务会自动维护Merkle树："
    echo "  - GenerateMerkleTreeJob: 每12小时生成（00:00和12:00）"
    echo "  - MerkleTreeGuardianJob: 每30分钟检查并自动修复"
    echo ""
}

# 显示状态
show_status() {
    echo -e "${BLUE}📊 Merkle树状态 (环境: $RAILS_ENV)${NC}"
    echo ""
    RAILS_ENV=$RAILS_ENV bundle exec rake merkle_tree:status
}

# 生成Merkle树
generate_tree() {
    local item_id=$1

    if [ -z "$item_id" ]; then
        echo -e "${GREEN}🌲 生成所有NFT集合的Merkle树 (环境: $RAILS_ENV)${NC}"
        echo ""
        RAILS_ENV=$RAILS_ENV bundle exec rake puzzlex:generate_merkle_trees
    else
        echo -e "${GREEN}🌲 为itemId ${item_id} 生成Merkle树 (环境: $RAILS_ENV)${NC}"
        echo ""
        RAILS_ENV=$RAILS_ENV bundle exec rake merkle_tree:generate[$item_id]
    fi
}

# 清理过期数据
cleanup_old_trees() {
    echo -e "${YELLOW}🧹 清理过期的Merkle树数据 (环境: $RAILS_ENV)${NC}"
    echo ""
    RAILS_ENV=$RAILS_ENV bundle exec rake merkle_tree:cleanup
}

# 验证Merkle树
verify_tree() {
    local item_id=$1

    if [ -z "$item_id" ]; then
        echo -e "${BLUE}🔍 验证所有Merkle树 (环境: $RAILS_ENV)${NC}"
        echo ""
        RAILS_ENV=$RAILS_ENV bundle exec rake merkle_tree:verify
    else
        echo -e "${BLUE}🔍 验证itemId ${item_id}的Merkle树 (环境: $RAILS_ENV)${NC}"
        echo ""
        RAILS_ENV=$RAILS_ENV bundle exec rake merkle_tree:verify[$item_id]
    fi
}

# 显示所有根
show_roots() {
    echo -e "${BLUE}🌳 Merkle树根哈希 (环境: $RAILS_ENV)${NC}"
    echo ""
    RAILS_ENV=$RAILS_ENV bundle exec rake merkle_tree:roots
}

# 手动触发Sidekiq Job
trigger_job() {
    echo -e "${GREEN}🚀 手动触发GenerateMerkleTreeJob (环境: $RAILS_ENV)${NC}"
    echo ""

    RAILS_ENV=$RAILS_ENV bundle exec rails runner "
      Jobs::Merkle::GenerateMerkleTreeJob.perform_async
      puts '✅ Job已加入队列，Sidekiq将异步处理'
      puts '💡 查看日志: tail -f log/sidekiq.log'
    "
}

# 主命令处理
COMMAND=${1:-help}

case $COMMAND in
    status)
        show_status
        ;;
    generate)
        generate_tree "$2"
        ;;
    cleanup)
        cleanup_old_trees
        ;;
    verify)
        verify_tree "$2"
        ;;
    roots)
        show_roots
        ;;
    trigger-job)
        trigger_job
        ;;
    help|--help|-h)
        show_help
        ;;
    *)
        echo -e "${RED}❌ 未知命令: $COMMAND${NC}"
        echo ""
        show_help
        exit 1
        ;;
esac
