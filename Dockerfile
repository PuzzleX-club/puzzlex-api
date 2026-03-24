# ====================================
# 统一 Dockerfile - 多阶段构建
# ====================================
# 支持 Build Args:
#   HTTP_PROXY/HTTPS_PROXY - 构建时代理（默认空）
#   INCLUDE_DEV_GEMS       - 是否包含 dev/test gems (true/false，默认 false)
#   BUNDLE_WITHOUT_ARG     - 排除的 gem 组（默认 "development test"）
# ====================================

# ============= Stage 1: Builder =============
FROM ruby:3.3-slim AS builder

# 构建时代理通过 ARG 传入，不硬编码
ARG HTTP_PROXY=""
ARG HTTPS_PROXY=""
ENV http_proxy=${HTTP_PROXY} https_proxy=${HTTPS_PROXY}

# Gems 安装控制：默认排除 dev/test
ARG INCLUDE_DEV_GEMS="false"
ARG BUNDLE_WITHOUT_ARG="development test"

# 安装构建依赖
RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y \
    autoconf \
    automake \
    build-essential \
    ca-certificates \
    default-libmysqlclient-dev \
    git \
    libpq-dev \
    libsecp256k1-dev \
    libtool \
    pkg-config \
    libssl-dev \
    && rm -rf /var/lib/apt/lists/*

# 设置工作目录
WORKDIR /app

# 复制 Gemfile（利用 Docker 层缓存）
COPY Gemfile Gemfile.lock ./

# 设置编译环境变量
ENV CFLAGS="-D_GNU_SOURCE" \
    BUNDLE_PATH="/usr/local/bundle"

# 配置 rbsecp256k1 使用系统库
RUN bundle config build.rbsecp256k1 --with-system-libraries

# 根据 INCLUDE_DEV_GEMS 决定是否排除 dev/test
RUN if [ "$INCLUDE_DEV_GEMS" = "true" ]; then \
      echo "Installing ALL gems (including dev/test)..."; \
      bundle config set --local without ''; \
    else \
      echo "Installing production gems (excluding: $BUNDLE_WITHOUT_ARG)..."; \
      bundle config set --local without "$BUNDLE_WITHOUT_ARG"; \
    fi

# 安装 gems
# 使用代理下载（如果构建时提供了代理参数）
RUN bundle install --jobs 4 --retry 3

# 清除构建时代理，避免泄漏到运行时
ENV http_proxy="" https_proxy=""

# ============= Stage 2: Runtime =============
FROM ruby:3.3-slim

# 安装运行时依赖
# procps: K8s 探针使用 ps 命令
# ca-certificates: SSL/TLS 连接所需的 CA 证书
RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y \
    ca-certificates \
    curl \
    default-mysql-client \
    libpq-dev \
    postgresql-client \
    redis-tools \
    tzdata \
    nodejs \
    procps \
    && rm -rf /var/lib/apt/lists/*

# 从构建阶段继承 BUNDLE_WITHOUT 设置
ARG INCLUDE_DEV_GEMS="false"
ARG BUNDLE_WITHOUT_ARG="development test"

# 设置环境变量
ENV TZ=Asia/Shanghai \
    BUNDLE_PATH="/usr/local/bundle" \
    PORT=3000

# 根据构建参数设置运行时 BUNDLE_WITHOUT
RUN if [ "$INCLUDE_DEV_GEMS" = "true" ]; then \
      echo "Runtime: dev/test gems included"; \
    else \
      echo "Runtime: BUNDLE_WITHOUT=$BUNDLE_WITHOUT_ARG"; \
    fi
ENV BUNDLE_WITHOUT=${INCLUDE_DEV_GEMS:+}${INCLUDE_DEV_GEMS:-$BUNDLE_WITHOUT_ARG}

# 创建应用用户（非 root）
RUN groupadd -r rails && useradd -r -g rails rails

# 设置工作目录
WORKDIR /app

# 从 builder 阶段复制 gems
COPY --from=builder /usr/local/bundle /usr/local/bundle

# 复制应用代码
COPY --chown=rails:rails . .

# 创建必要的目录并设置权限
RUN mkdir -p tmp/pids tmp/cache tmp/sockets log storage shared/log shared/sockets && \
    chown -R rails:rails tmp log storage shared/log shared/sockets && \
    chmod -R 755 tmp log storage shared/log shared/sockets

# 复制统一入口点脚本
COPY bin/docker-entrypoint /usr/local/bin/docker-entrypoint
# 需要 755 权限：rails 用户需要读取+执行权限才能运行 bash 脚本
RUN chmod 755 /usr/local/bin/docker-entrypoint

# 切换到非 root 用户
USER rails

# 暴露端口（可通过 -p 或 K8s 配置覆盖）
EXPOSE 3000

# 健康检查
HEALTHCHECK --interval=30s --timeout=3s --start-period=40s --retries=3 \
  CMD curl -f http://localhost:${PORT:-3000}/health || exit 1

# 入口点
ENTRYPOINT ["/usr/local/bin/docker-entrypoint"]

# 默认命令
CMD ["bundle", "exec", "rails", "server", "-b", "0.0.0.0"]
