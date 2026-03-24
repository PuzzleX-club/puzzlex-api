# frozen_string_literal: true

module Client
  module IndexerAvailabilityHandling
    extend ActiveSupport::Concern

    included do
      rescue_from ActiveRecord::ConnectionNotEstablished, with: :render_indexer_unavailable
      rescue_from ActiveRecord::ConnectionTimeoutError, with: :render_indexer_unavailable
      rescue_from PG::ConnectionBad, with: :render_indexer_unavailable if defined?(PG::ConnectionBad)
    end

    private

    def render_indexer_unavailable(exception)
      Rails.logger.error "[Indexer] 数据库连接失败: #{exception.class} - #{exception.message}"
      render json: {
        code: 503,
        message: "Indexer 服务不可用，请稍后重试",
        data: { error_code: "INDEXER_UNAVAILABLE" }
      }, status: :service_unavailable
    end
  end
end
