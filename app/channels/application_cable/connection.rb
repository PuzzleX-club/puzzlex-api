module ApplicationCable
  class Connection < ActionCable::Connection::Base
    identified_by :current_user

    # 捕捉标准错误并上报
    rescue_from StandardError, with: :report_error

    def connect
      # 进行jwt鉴权 - 从URL查询参数获取token
      # WebSocket连接时，token在URL查询字符串中
      Rails.logger.info("[WebSocket] Request URL: #{request.url}")
      Rails.logger.info("[WebSocket] Request PATH: #{request.path}")
      Rails.logger.info("[WebSocket] Request QUERY_STRING: #{request.query_string}")
      
      # 手动解析查询字符串
      query_params = Rack::Utils.parse_query(request.query_string)
      token = query_params["token"]
      
      Rails.logger.info("[WebSocket] 解析后的查询参数: #{query_params.inspect}")
      Rails.logger.info("[WebSocket] Token: #{token&.first(20)}...") if token
      Rails.logger.info("[WebSocket] 开始连接验证, token存在: #{token.present?}")
      Rails.logger.info("[WebSocket] 当前环境: #{Rails.env}")
      Rails.logger.info("[WebSocket] 数据库连接状态: #{ActiveRecord::Base.connected?}")
      
      if token.blank?
        Rails.logger.error("[WebSocket] Token为空，拒绝连接")
        reject_unauthorized_connection
      else
        begin
          secret_key = Rails.application.config.x.auth.jwt_secret
          
          payload, _ = JWT.decode(token, secret_key, true, algorithm: 'HS256')
          user_id = payload["user_id"]
          Rails.logger.info("[WebSocket] JWT解码成功, user_id: #{user_id}, payload: #{payload.inspect}")
          
          # 查找puzzlex用户表中的用户
          Rails.logger.info("[WebSocket] 开始查找用户 ID=#{user_id}")
          @current_user = Accounts::User.find_by(id: user_id)
          
          if @current_user
            Rails.logger.info("[WebSocket] 用户验证成功: #{@current_user.id} - #{@current_user.address}")
            self.current_user = @current_user
            Rails.logger.info("[WebSocket] ✅ 连接建立成功")
          else
            Rails.logger.error("[WebSocket] User not found for user_id: #{user_id}")
            Rails.logger.error("[WebSocket] 所有用户ID: #{Accounts::User.pluck(:id).join(', ')}")
            reject_unauthorized_connection
          end
        rescue JWT::DecodeError => e
          Rails.logger.error("[WebSocket] JWT解码失败: #{e.message}")
          Rails.logger.error("[WebSocket] Token: #{token}")
          reject_unauthorized_connection
        rescue ActiveRecord::ConnectionTimeoutError => e
          Rails.logger.error("[WebSocket] 数据库连接超时: #{e.message}")
          reject_unauthorized_connection  
        rescue => e
          Rails.logger.error("[WebSocket] 未知错误: #{e.class.name} - #{e.message}")
          Rails.logger.error("[WebSocket] Backtrace: #{e.backtrace.first(5).join("\n")}")
          reject_unauthorized_connection
        end
      end
    end

    private
    # 错误报告逻辑
    def report_error(e)
      Rails.logger.error("ActionCable Error: #{e.class} - #{e.message}")
      Rails.logger.error(e.backtrace.join("\n")) if e.backtrace
    end
  end
end
