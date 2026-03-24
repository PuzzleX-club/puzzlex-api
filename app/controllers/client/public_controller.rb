# frozen_string_literal: true

module Client
  # Client::PublicController - 客户端公开 API 基类
  class PublicController < ApplicationController
    private

    def render_error(message, status = :bad_request)
      render json: { code: status, message: message }, status: status
    end

    def render_success(data = nil, message = 'success')
      render json: { code: 200, message: message, data: data }
    end
  end
end
