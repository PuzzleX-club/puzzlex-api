#!/bin/bash
set -e

# 环境变量验证脚本
# 用途: 验证环境变量的完整性和格式
# 使用方法:
#   ./scripts/validate-env.sh --environment <env> [--from-file <file>|--from-github]
#
# 参数:
#   --environment <env>    必选: 要验证的环境 (dev|prod|test)
#   --from-file <file>     可选: 从 .env 文件验证
#   --from-github          可选: 从 GitHub Environment 验证
#   --strict               可选: 严格模式（可选变量也必须存在）
#
# 示例:
#   ./scripts/validate-env.sh --environment dev --from-file .env.dev.trading
#   ./scripts/validate-env.sh --environment prod --from-file .env.prod
#   ./scripts/validate-env.sh --environment prod --from-github --strict

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

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

# 脚本目录
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCHEMA_FILE="$SCRIPT_DIR/config/environment-schema.yml"

# 参数
ENVIRONMENT=""
SOURCE_TYPE=""
SOURCE_FILE=""
STRICT_MODE=false

# 解析参数
while [[ $# -gt 0 ]]; do
    case $1 in
        --environment)
            ENVIRONMENT="$2"
            shift 2
            ;;
        --from-file)
            SOURCE_TYPE="file"
            SOURCE_FILE="$2"
            shift 2
            ;;
        --from-github)
            SOURCE_TYPE="github"
            shift
            ;;
        --strict)
            STRICT_MODE=true
            shift
            ;;
        *)
            log_error "未知参数: $1"
            exit 1
            ;;
    esac
done

# 验证参数
if [[ -z "$ENVIRONMENT" ]]; then
    log_error "缺少 --environment 参数"
    exit 1
fi

if [[ ! "$ENVIRONMENT" =~ ^(dev|prod|test)$ ]]; then
    log_error "无效的环境: $ENVIRONMENT (必须是 dev, prod, 或 test)"
    exit 1
fi

if [[ -z "$SOURCE_TYPE" ]]; then
    log_error "必须指定 --from-file 或 --from-github"
    exit 1
fi

log_info "🔍 环境变量验证"
log_info "  环境: $ENVIRONMENT"
log_info "  来源: $SOURCE_TYPE"
if [[ "$SOURCE_TYPE" == "file" ]]; then
    log_info "  文件: $SOURCE_FILE"
fi
log_info "  严格模式: $STRICT_MODE"
echo ""

# 检查 Schema 文件
if [[ ! -f "$SCHEMA_FILE" ]]; then
    log_error "❌ Schema 文件不存在: $SCHEMA_FILE"
    exit 1
fi

# 检查 yq 工具
if ! command -v yq &> /dev/null; then
    log_error "❌ yq 未安装，无法解析 YAML"
    log_info "安装命令: brew install yq"
    exit 1
fi

# 从 Schema 加载必需变量
REQUIRED_SECRETS=$(yq eval '.required_secrets[].name' "$SCHEMA_FILE")
REQUIRED_VARIABLES=$(yq eval '.required_variables[].name' "$SCHEMA_FILE")
OPTIONAL_SECRETS=$(yq eval '.optional_secrets[].name' "$SCHEMA_FILE")
OPTIONAL_VARIABLES=$(yq eval '.optional_variables[].name' "$SCHEMA_FILE")

log_info "📋 从 Schema 加载配置:"
log_info "  必需 Secrets: $(echo "$REQUIRED_SECRETS" | wc -l | tr -d ' ') 个"
log_info "  必需 Variables: $(echo "$REQUIRED_VARIABLES" | wc -l | tr -d ' ') 个"
log_info "  可选 Secrets: $(echo "$OPTIONAL_SECRETS" | wc -l | tr -d ' ') 个"
log_info "  可选 Variables: $(echo "$OPTIONAL_VARIABLES" | wc -l | tr -d ' ') 个"
echo ""

# 初始化计数器
TOTAL_CHECKS=0
PASSED_CHECKS=0
FAILED_CHECKS=0
WARNING_CHECKS=0

# 验证函数
validate_variable() {
    local var_name=$1
    local var_value=$2
    local var_type=$3  # secret 或 variable
    local is_required=$4  # true 或 false

    TOTAL_CHECKS=$((TOTAL_CHECKS + 1))

    # 检查是否存在
    if [[ -z "$var_value" ]]; then
        if [[ "$is_required" == "true" ]]; then
            log_error "  ❌ $var_name: 缺失 (必需的 $var_type)"
            FAILED_CHECKS=$((FAILED_CHECKS + 1))
            return 1
        elif [[ "$STRICT_MODE" == "true" ]]; then
            log_warning "  ⚠️  $var_name: 缺失 (可选的 $var_type，严格模式)"
            WARNING_CHECKS=$((WARNING_CHECKS + 1))
            return 0
        else
            log_info "  ℹ️  $var_name: 缺失 (可选的 $var_type)"
            return 0
        fi
    fi

    # 获取格式规则
    local format=$(yq eval ".${var_type}s[] | select(.name==\"$var_name\") | .format" "$SCHEMA_FILE")

    if [[ -n "$format" && "$format" != "null" ]]; then
        # 获取验证模式
        local pattern=$(yq eval ".validation_rules.${format}.pattern" "$SCHEMA_FILE" 2>/dev/null || echo "")

        if [[ -n "$pattern" && "$pattern" != "null" ]]; then
            if [[ ! "$var_value" =~ $pattern ]]; then
                local error_msg=$(yq eval ".validation_rules.${format}.error_message" "$SCHEMA_FILE")
                log_error "  ❌ $var_name: 格式错误 - $error_msg"
                FAILED_CHECKS=$((FAILED_CHECKS + 1))
                return 1
            fi
        fi
    fi

    # 检查长度限制
    local min_length=$(yq eval ".${var_type}s[] | select(.name==\"$var_name\") | .min_length" "$SCHEMA_FILE" 2>/dev/null || echo "")
    if [[ -n "$min_length" && "$min_length" != "null" ]]; then
        if [[ ${#var_value} -lt $min_length ]]; then
            log_error "  ❌ $var_name: 长度不足 (最小 $min_length 字符)"
            FAILED_CHECKS=$((FAILED_CHECKS + 1))
            return 1
        fi
    fi

    log_success "  ✅ $var_name: 有效"
    PASSED_CHECKS=$((PASSED_CHECKS + 1))
    return 0
}

# 从文件验证
if [[ "$SOURCE_TYPE" == "file" ]]; then
    if [[ ! -f "$SOURCE_FILE" ]]; then
        log_error "❌ 文件不存在: $SOURCE_FILE"
        exit 1
    fi

    log_info "📝 从文件验证: $SOURCE_FILE"
    echo ""

    # 加载文件
    source "$SOURCE_FILE"

    # 验证必需 Secrets
    log_info "🔐 验证必需 Secrets:"
    while IFS= read -r var_name; do
        validate_variable "$var_name" "${!var_name}" "required_secret" "true"
    done <<< "$REQUIRED_SECRETS"
    echo ""

    # 验证必需 Variables
    log_info "📊 验证必需 Variables:"
    while IFS= read -r var_name; do
        validate_variable "$var_name" "${!var_name}" "required_variable" "true"
    done <<< "$REQUIRED_VARIABLES"
    echo ""

    # 验证可选 Secrets
    if [[ "$STRICT_MODE" == "true" ]]; then
        log_info "🔐 验证可选 Secrets (严格模式):"
        while IFS= read -r var_name; do
            validate_variable "$var_name" "${!var_name}" "optional_secret" "false"
        done <<< "$OPTIONAL_SECRETS"
        echo ""
    fi

    # 验证可选 Variables
    if [[ "$STRICT_MODE" == "true" ]]; then
        log_info "📊 验证可选 Variables (严格模式):"
        while IFS= read -r var_name; do
            validate_variable "$var_name" "${!var_name}" "optional_variable" "false"
        done <<< "$OPTIONAL_VARIABLES"
        echo ""
    fi
fi

# 从 GitHub 验证
if [[ "$SOURCE_TYPE" == "github" ]]; then
    # 检查 gh CLI
    if ! command -v gh &> /dev/null; then
        log_error "❌ GitHub CLI (gh) 未安装"
        log_info "安装命令: brew install gh"
        exit 1
    fi

    if ! gh auth status &> /dev/null; then
        log_error "❌ GitHub CLI 未认证"
        log_info "请先运行: gh auth login"
        exit 1
    fi

    log_info "📦 从 GitHub Environment 验证: $ENVIRONMENT"
    echo ""

    # 获取 Secrets 列表
    SECRET_NAMES=$(gh secret list --env "$ENVIRONMENT" --json name 2>/dev/null | jq -r '.[].name' || echo "")

    # 获取 Variables 列表和值
    VARIABLES_JSON=$(gh variable list --env "$ENVIRONMENT" --json name,value 2>/dev/null || echo "{}")

    # 验证必需 Secrets
    log_info "🔐 验证必需 Secrets:"
    while IFS= read -r var_name; do
        if echo "$SECRET_NAMES" | grep -q "^${var_name}$"; then
            log_success "  ✅ $var_name: 存在"
            PASSED_CHECKS=$((PASSED_CHECKS + 1))
        else
            log_error "  ❌ $var_name: 缺失"
            FAILED_CHECKS=$((FAILED_CHECKS + 1))
        fi
        TOTAL_CHECKS=$((TOTAL_CHECKS + 1))
    done <<< "$REQUIRED_SECRETS"
    echo ""

    # 验证必需 Variables
    log_info "📊 验证必需 Variables:"
    while IFS= read -r var_name; do
        var_value=$(echo "$VARIABLES_JSON" | jq -r ".[] | select(.name==\"$var_name\") | .value" 2>/dev/null || echo "")
        validate_variable "$var_name" "$var_value" "required_variable" "true"
    done <<< "$REQUIRED_VARIABLES"
    echo ""

    # 验证可选 Secrets
    if [[ "$STRICT_MODE" == "true" ]]; then
        log_info "🔐 验证可选 Secrets (严格模式):"
        while IFS= read -r var_name; do
            if echo "$SECRET_NAMES" | grep -q "^${var_name}$"; then
                log_success "  ✅ $var_name: 存在"
                PASSED_CHECKS=$((PASSED_CHECKS + 1))
            else
                log_warning "  ⚠️  $var_name: 缺失 (可选)"
                WARNING_CHECKS=$((WARNING_CHECKS + 1))
            fi
            TOTAL_CHECKS=$((TOTAL_CHECKS + 1))
        done <<< "$OPTIONAL_SECRETS"
        echo ""
    fi

    # 验证可选 Variables
    if [[ "$STRICT_MODE" == "true" ]]; then
        log_info "📊 验证可选 Variables (严格模式):"
        while IFS= read -r var_name; do
            var_value=$(echo "$VARIABLES_JSON" | jq -r ".[] | select(.name==\"$var_name\") | .value" 2>/dev/null || echo "")
            validate_variable "$var_name" "$var_value" "optional_variable" "false"
        done <<< "$OPTIONAL_VARIABLES"
        echo ""
    fi
fi

# 显示验证结果
echo "======================================"
log_info "📊 验证结果汇总"
echo "======================================"
echo ""
echo "  总检查项: $TOTAL_CHECKS"
echo -e "  ${GREEN}✅ 通过: $PASSED_CHECKS${NC}"
if [[ $WARNING_CHECKS -gt 0 ]]; then
    echo -e "  ${YELLOW}⚠️  警告: $WARNING_CHECKS${NC}"
fi
if [[ $FAILED_CHECKS -gt 0 ]]; then
    echo -e "  ${RED}❌ 失败: $FAILED_CHECKS${NC}"
fi
echo ""

# 返回退出码
if [[ $FAILED_CHECKS -gt 0 ]]; then
    log_error "❌ 验证失败，存在 $FAILED_CHECKS 个错误"
    exit 1
else
    log_success "✅ 验证通过"
    if [[ $WARNING_CHECKS -gt 0 ]]; then
        log_warning "⚠️  存在 $WARNING_CHECKS 个警告（可选变量缺失）"
    fi
    exit 0
fi
