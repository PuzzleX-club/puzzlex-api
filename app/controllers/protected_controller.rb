# frozen_string_literal: true

# 受保护控制器基类
# 提供共享的认证、当前用户和标准响应辅助方法
class ProtectedController < ApplicationController
  include Authentication

  before_action :authenticate_request!

  private

  def render_error(message, status = :bad_request)
    render json: { code: status, message: message }, status: status
  end

  def render_success(data = nil, message = 'success')
    render json: { code: 200, message: message, data: data }
  end

  def current_user
    @current_user
  end

  def require_authenticated_user
    head :unauthorized unless current_user
  end
end
