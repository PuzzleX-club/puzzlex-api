# frozen_string_literal: true

# app/controllers/admin/users_controller.rb
#
# Admin 用户管理控制器
# 提供用户列表查询和管理员权限管理
#
# API 端点:
#   GET  /api/admin/users                   - 获取用户列表
#   POST /api/admin/users/:id/grant_admin   - 授予管理员权限
#   POST /api/admin/users/:id/revoke_admin  - 撤销管理员权限
#
# 权限:
#   - index: Admin
#   - grant_admin/revoke_admin: SuperAdmin

module Admin
  class UsersController < ::Admin::ApplicationController
    # 权限管理操作需要超级管理员权限
    before_action :require_super_admin!, only: [:grant_admin, :revoke_admin]

    # GET /api/admin/users
    # 获取用户列表（支持分页和过滤）
    #
    # 参数:
    #   page - 页码（默认 1）
    #   per_page - 每页数量（默认 20，最大 100）
    #   admin_level - 按权限级别过滤 (user/admin/super_admin)
    #   search - 搜索地址
    #
    # 响应:
    #   {
    #     code: 0,
    #     message: "Success",
    #     data: {
    #       users: [...],
    #       meta: { current_page, total_pages, total_count, per_page }
    #     }
    #   }
    def index
      users = Accounts::User.all

      # 过滤条件
      if params[:admin_level].present? && Accounts::User.admin_levels.key?(params[:admin_level])
        users = users.where(admin_level: params[:admin_level])
      end

      # 地址搜索
      if params[:search].present?
        search_term = "%#{params[:search].downcase}%"
        users = users.where('address ILIKE ?', search_term)
      end

      # 排序（管理员优先，然后按创建时间）
      users = users.order(admin_level: :desc, created_at: :desc)

      # 分页
      page_params = pagination_params
      users = users.page(page_params[:page]).limit(page_params[:per_page])

      render_success({
        users: users.map { |user| serialize_user(user) },
        meta: pagination_meta(users)
      })
    end

    # POST /api/admin/users/:id/grant_admin
    # 授予管理员权限
    #
    # 参数:
    #   level - 权限级别 (admin/super_admin，默认 admin)
    #
    # 响应:
    #   {
    #     code: 0,
    #     message: "Admin granted successfully",
    #     data: { user: {...} }
    #   }
    def grant_admin
      user = Accounts::User.find_by(id: params[:id])
      unless user
        return render_error("User not found", status: :not_found, code: 404)
      end

      level = params[:level] || 'admin'
      unless %w[admin super_admin].include?(level)
        return render_error("Invalid admin level: #{level}", status: :unprocessable_entity, code: 422)
      end

      # 不能给自己授权（防止误操作）
      if user.id == current_user.id
        return render_error("Cannot modify your own admin level", status: :forbidden, code: 403)
      end

      if user.update(admin_level: level)
        Rails.logger.info "[Admin] User #{current_user.address} granted #{level} to #{user.address}"
        render_success({ user: serialize_user(user) }, message: "Admin granted successfully")
      else
        render_error(user.errors.full_messages.join(', '), status: :unprocessable_entity, code: 422)
      end
    end

    # POST /api/admin/users/:id/revoke_admin
    # 撤销管理员权限
    #
    # 响应:
    #   {
    #     code: 0,
    #     message: "Admin revoked successfully",
    #     data: { user: {...} }
    #   }
    def revoke_admin
      user = Accounts::User.find_by(id: params[:id])
      unless user
        return render_error("User not found", status: :not_found, code: 404)
      end

      # 不能撤销自己的权限
      if user.id == current_user.id
        return render_error("Cannot revoke your own admin level", status: :forbidden, code: 403)
      end

      # 检查是否是最后一个超级管理员
      if user.super_admin? && Accounts::User.super_admin.count <= 1
        return render_error("Cannot revoke the last super admin", status: :forbidden, code: 403)
      end

      if user.update(admin_level: :user)
        Rails.logger.info "[Admin] User #{current_user.address} revoked admin from #{user.address}"
        render_success({ user: serialize_user(user) }, message: "Admin revoked successfully")
      else
        render_error(user.errors.full_messages.join(', '), status: :unprocessable_entity, code: 422)
      end
    end

    private

    def serialize_user(user)
      {
        id: user.id,
        address: user.address,
        admin_level: user.admin_level,
        is_admin: user.admin?,
        is_super_admin: user.super_admin?,
        created_at: user.created_at.iso8601,
        updated_at: user.updated_at.iso8601
      }
    end
  end
end
