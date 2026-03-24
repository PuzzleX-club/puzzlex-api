# frozen_string_literal: true

# System::HealthController - 系统健康检查控制器
# ==============================================
# 用于编排器探针和负载均衡器健康检查
# 必须保持公开访问，不需要任何认证
#
# 继承关系：
#   ApplicationController
#   └── System::HealthController (本类)
#
module System
  class HealthController < ::ApplicationController
    # GET /health
    def show
      render json: {
        status: 'ok',
        timestamp: Time.current,
        environment: Rails.env
      }, status: :ok
    rescue => e
      render json: {
        status: 'error',
        message: e.message,
        timestamp: Time.current
      }, status: :service_unavailable
    end

    # GET /health/sidekiq
    def sidekiq
      process_set = Sidekiq::ProcessSet.new
      processes = process_set.to_a

      if processes.any?
        current_hostname = ENV['HOSTNAME'] || Socket.gethostname
        current_process = processes.find { |p| p['hostname'] == current_hostname }

        render json: {
          status: 'ok',
          sidekiq: 'running',
          process_count: processes.size,
          current_process: current_process ? {
            hostname: current_process['hostname'],
            concurrency: current_process['concurrency'],
            queues: current_process['queues'],
            busy: current_process['busy']
          } : nil,
          timestamp: Time.current
        }, status: :ok
      else
        render json: {
          status: 'error',
          sidekiq: 'not_running',
          message: 'No Sidekiq processes found',
          timestamp: Time.current
        }, status: :service_unavailable
      end
    rescue => e
      render json: {
        status: 'error',
        sidekiq: 'unknown',
        message: e.message,
        timestamp: Time.current
      }, status: :service_unavailable
    end

    # 调试 Admin 配置
    def admin_debug
      render json: {
        admin_features_enabled: Rails.application.config.admin_features_enabled,
        rails_env: Rails.env,
        timestamp: Time.current
      }
    end
  end
end
