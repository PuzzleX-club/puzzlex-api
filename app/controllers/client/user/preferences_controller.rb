# frozen_string_literal: true

# 用户偏好设置控制器
# 提供偏好 CRUD 操作
class Client::User::PreferencesController < ::Client::ProtectedController
  before_action :set_project

  # 获取所有偏好
  # GET /api/user/preferences
  def index
    preferences = User::PreferenceService.get_all_preferences(current_user, @project)
    render_success(preferences)
  end

  # 获取单个偏好
  # GET /api/user/preferences/:key
  def show
    key = params[:key]

    if key.blank?
      return render_error('key 不能为空', :bad_request)
    end

    value = User::PreferenceService.get_preference(current_user, key, @project)

    if value.nil?
      render_error('偏好不存在', :not_found)
    else
      render_success({ key: key, value: value })
    end
  end

  # 保存偏好
  # PUT /api/user/preferences/:key
  def update
    key = params[:key]
    value = params[:value]

    if key.blank?
      return render_error('key 不能为空', :bad_request)
    end

    # 支持在请求体中传递 key
    if value.nil? && request.content_type&.include?('application/json')
      json_body = JSON.parse(request.body.read) rescue {}
      value = json_body['value'] if json_body['key'] == key || json_body.key?('value')
    end

    pref = User::PreferenceService.set_preference(current_user, key, value, @project)
    render_success({ key: key, value: pref.value, version: pref.version }, '保存偏好成功')
  end

  # 批量保存偏好
  # PUT /api/user/preferences/batch
  def batch_update
    # 支持 JSON body 或 form parameters
    if request.content_type&.include?('application/json')
      preferences = JSON.parse(request.body.read) rescue {}
    else
      preferences = params[:preferences] || params.except(:controller, :action, :project).permit!.to_h
    end

    if preferences.blank? || !preferences.is_a?(Hash)
      return render_error('preferences 必须是一个对象', :bad_request)
    end

    User::PreferenceService.batch_set_preferences(current_user, preferences, @project)
    updated = User::PreferenceService.get_all_preferences(current_user, @project)
    render_success(updated, '批量保存偏好成功')
  end

  # 删除偏好
  # DELETE /api/user/preferences/:key
  def destroy
    key = params[:key]

    if key.blank?
      return render_error('key 不能为空', :bad_request)
    end

    count = User::PreferenceService.delete_preference(current_user, key, @project)

    if count > 0
      render_success(nil, '删除偏好成功')
    else
      render_error('偏好不存在', :not_found)
    end
  end

  private

  def set_project
    @project = params[:project]
    return if @project.present?

    @project = Rails.application.config.x.project.default_key
    Rails.logger.info "[Client::User::PreferencesController] ⚠️ 未提供 project，降级使用默认值: #{@project}"
  end
end
