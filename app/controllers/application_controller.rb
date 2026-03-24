# frozen_string_literal: true

# ApplicationController - 基础控制器
# =====================================
# 所有控制器的根基类，继承自 ActionController::API 以支持 API-only 模式
# 提供全局通用配置，不包含认证逻辑（认证由子类处理）
#
# 继承关系：
#   ActionController::API
#   └── ApplicationController (本类)
#       ├── ProtectedController (共享受保护接口基类)
#       │   ├── Admin::ApplicationController (Admin 功能基类)
#       │   └── Client::ProtectedController (客户端受保护 API 基类)
#       ├── Client::ApplicationController (客户端边界基类)
#       │   ├── Client::PublicController (客户端公开 API 基类)
#       │   └── Client::Auth::* / Client::User::* / Client::Explorer::* 等业务控制器
#       └── 其他顶层共享基类或系统入口
#
class ApplicationController < ActionController::API
  # 移除无效模块引用
  # - UserProfile: 使用了 helper_method，API模式不支持
  # - CrossTableQuery: 已被标记为 deprecated
  # 如果将来需要这些功能，应该重新实现为 API 兼容的版本

  # ============= 全局配置 =============
  # 所有控制器都需要的基础设置
  before_action :set_locale      # 从请求头或参数设置语言
  before_action :set_time_zone   # 根据语言设置时区

  # ============= 全局错误处理 =============
  # 统一的错误响应格式
  rescue_from ActiveRecord::RecordNotFound, with: :record_not_found
  rescue_from ActionController::ParameterMissing, with: :bad_request
  rescue_from ::RpcServiceError, with: :rpc_unavailable
  rescue_from StandardError, with: :internal_server_error if Rails.env.production?

  def record_not_found
    render json: {
      error: "记录未找到",
      code: 404
    }, status: :not_found
  end

  def bad_request(exception)
    render json: {
      error: exception.message,
      code: 400
    }, status: :bad_request
  end

  def internal_server_error(exception)
    Rails.logger.error "Internal Server Error: #{exception.message}"
    Rails.logger.error exception.backtrace.join("\n") if Rails.env.development?

    render json: {
      error: "服务器内部错误",
      code: 500
    }, status: :internal_server_error
  end

  def rpc_unavailable(exception)
    Rails.logger.error "[RPC] 服务不可用: #{exception.class} - #{exception.message}"
    render json: {
      error: "RPC 服务不可用，请稍后重试",
      code: 503,
      data: { error_code: "RPC_UNAVAILABLE" }
    }, status: :service_unavailable
  end


  private

  def set_locale
    # API 模式：从请求参数或请求头获取语言设置
    I18n.locale = params[:locale] || extract_locale_from_accept_language_header || I18n.default_locale
  end

  def extract_locale_from_accept_language_header
    accept_language = request.env['HTTP_ACCEPT_LANGUAGE']

    if accept_language.nil? || accept_language.empty?
      # 如果请求头为空或不存在，则使用默认语言
      Rails.logger.warn "Accept-Language header is missing or empty. Using default language."
      return I18n.default_locale.to_s  # 或者 `I18n.default_locale.to_s`，根据你的应用配置来定
    end

    # 提取前两个字符作为语言代码
    language = accept_language.scan(/^[a-z]{2}/).first

    if language&.downcase == "zh"
      language = "zh-CN"
    else
      language = "en"
    end

    language
  end

  def set_time_zone
    case I18n.locale
    when :"zh-CN"
      Time.zone = 'Beijing'  # 对应中文，设置为北京时间
    when :en
      Time.zone = 'UTC'      # 对应英文，设置为协调世界时
    else
      Time.zone = 'UTC'      # 默认时区
    end
  end

  # API-only 模式不需要主题设置
  # 客户端应该管理自己的主题




end
