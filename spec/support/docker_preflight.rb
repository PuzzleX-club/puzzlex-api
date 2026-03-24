# frozen_string_literal: true

# Docker 容器前置检查
# 在测试套件启动前检查必要的 Docker 容器是否运行
#
# 依赖容器:
#   - test_postgres (port 5434) : PostgreSQL 测试数据库
#   - redis_test    (port 6381) : Redis 测试实例
#
# 可通过环境变量自定义:
#   DOCKER_COMPOSE_DIR - docker-compose 文件所在目录

module DockerPreflight
  REQUIRED_CONTAINERS = {
    'test_postgres' => { port: 5434, service: 'PostgreSQL' },
    'redis_test'    => { port: 6381, service: 'Redis' }
  }.freeze

  COMPOSE_DIR = ENV.fetch('DOCKER_COMPOSE_DIR', File.expand_path('~/localdata/dockerfile')).freeze

  class << self
    def check!
      missing = detect_missing_containers
      return if missing.empty?

      warn_and_abort(missing)
    end

    private

    def detect_missing_containers
      REQUIRED_CONTAINERS.each_with_object([]) do |(name, info), missing|
        unless container_running?(name)
          missing << { name: name, port: info[:port], service: info[:service] }
        end
      end
    end

    def container_running?(name)
      output = `docker inspect -f '{{.State.Running}}' #{name} 2>/dev/null`.strip
      output == 'true'
    end

    def warn_and_abort(missing)
      names = missing.map { |m| "#{m[:service]} (#{m[:name]}, port #{m[:port]})" }

      message = <<~MSG

        ╔══════════════════════════════════════════════════════════╗
        ║  Docker 容器未运行 - 单元测试需要以下服务              ║
        ╠══════════════════════════════════════════════════════════╣
        ║                                                          ║
        #{names.map { |n| "║  ✗ #{n.ljust(54)}║" }.join("\n")}
        ║                                                          ║
        ╠══════════════════════════════════════════════════════════╣
        ║  启动命令:                                               ║
        ║  cd #{COMPOSE_DIR.ljust(50)}║
        ║  docker compose up -d test-postgres redis-test           ║
        ╚══════════════════════════════════════════════════════════╝

      MSG

      abort(message)
    end
  end
end

# 仅在测试环境中执行检查
if defined?(RSpec) && Rails.env.test?
  RSpec.configure do |config|
    config.before(:suite) do
      DockerPreflight.check!
    end
  end
end
