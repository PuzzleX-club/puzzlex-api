module Authentication
  extend ActiveSupport::Concern

  included do
    # 子类可以选择是否自动应用认证
    # ProtectedController 会自动应用
    # TradesController 会条件应用
  end

  def authenticate_request!
    auth_header = request.headers['Authorization']
    if auth_header.blank?
      return render json: { error: "请先登录后再操作" }, status: :unauthorized
    end

    token = auth_header.split(" ").last
    begin
      decoded = JWT.decode(token, Rails.application.config.x.auth.jwt_secret, true, { algorithm: 'HS256' })
      payload = decoded.first
      if payload['exp'] && Time.now.to_i > payload['exp']
        return render json: { error: "Token expired" }, status: :unauthorized
      end
      # todo：需要调整筛选user的字段，应该是通过address
      @current_user = Accounts::User.find(payload["user_id"])
      @current_address = payload["address"]
      @current_chain_id = payload["chain_id"]
    rescue JWT::DecodeError => e
      Rails.logger.warn "JWT decode error: #{e.message}"
      render json: { error: "请先登录后再操作" }, status: :unauthorized
    rescue ActiveRecord::RecordNotFound
      render json: { error: "User not found" }, status: :unauthorized
    end
  end

  # 获取当前 chain_id（从 JWT payload 中提取）
  def current_chain_id
    @current_chain_id
  end

  # 获取当前用户地址
  def current_address
    @current_address
  end
end
