# frozen_string_literal: true

# Admin::ApplicationController - Admin 模块基类
class Admin::ApplicationController < ::ProtectedController
  before_action :require_admin

  private

  def require_admin
    return if admin_auth_skipped?
    return head :unauthorized unless current_user&.admin?
  end

  def admin_auth_skipped?
    Rails.application.config.x.admin.skip_auth
  end

  def authenticate_request!
    return if admin_auth_skipped?
    super
  end

  def require_super_admin!
    return head :unauthorized unless current_user&.super_admin?
  end

  def pagination_params
    {
      page: [params[:page].to_i, 1].max,
      per_page: [[params[:per_page].to_i, 1].max, 100].min
    }
  end

  def pagination_meta(collection)
    {
      current_page: collection.current_page,
      total_pages: collection.total_pages,
      total_count: collection.total_entries,
      per_page: collection.limit_value
    }
  end

  def render_success(data = nil, message = 'Success', code: 0)
    response_hash = {
      code: code,
      message: message
    }
    response_hash[:data] = data if data.present?
    render json: response_hash
  end

  def render_error(message, status: :bad_request, code: status)
    render json: {
      code: code,
      message: message
    }, status: status
  end
end
