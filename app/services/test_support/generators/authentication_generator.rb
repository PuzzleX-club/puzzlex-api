# 测试认证数据生成器
# 基于真实SIWE认证流程生成测试认证数据

module TestSupport
  module Generators
    class AuthenticationGenerator
      attr_reader :logger
    
    def initialize(logger = Rails.logger)
      @logger = logger
    end
    
    # 为测试用户生成完整的认证流程数据
    def generate_authentication_flow(user_address, private_key = nil)
      logger.info "🔐 开始为用户 #{user_address} 生成认证流程数据"
      
      # 第1步：创建或查找用户
      user = find_or_create_test_user(user_address)
      
      # 第2步：生成SIWE消息
      siwe_message = generate_siwe_message(user_address)
      
      # 第3步：模拟钱包签名（如果有私钥）
      signature = if private_key
        simulate_wallet_signature(siwe_message, private_key)
      else
        generate_mock_signature(siwe_message)
      end
      
      # 第4步：通过真实认证API生成JWT
      jwt_token = authenticate_with_backend(siwe_message, signature)
      
      # 第5步：记录认证会话
      auth_session = create_auth_session(user, jwt_token, siwe_message, signature)
      
      logger.info "✅ 认证流程生成完成: JWT Token长度 #{jwt_token&.length}"
      
      {
        user: user,
        siwe_message: siwe_message,
        signature: signature,
        jwt_token: jwt_token,
        auth_session: auth_session,
        authenticated_at: Time.current
      }
    end
    
    # 批量生成多个用户的认证数据
    def generate_multiple_authentications(user_configs)
      logger.info "🔐 批量生成 #{user_configs.count} 个用户的认证数据"
      
      results = []
      
      user_configs.each_with_index do |config, index|
        begin
          auth_data = generate_authentication_flow(
            config[:address], 
            config[:private_key]
          )
          
          results << {
            **auth_data,
            user_role: config[:role] || 'trader',
            user_nickname: config[:nickname] || "测试用户#{index + 1}"
          }
          
          logger.info "  ✅ 用户 #{index + 1}/#{user_configs.count} 认证生成完成"
          
        rescue => e
          logger.error "❌ 用户 #{config[:address]} 认证生成失败: #{e.message}"
          results << { error: e.message, user_address: config[:address] }
        end
      end
      
      success_count = results.count { |r| !r.key?(:error) }
      logger.info "✅ 批量认证生成完成: #{success_count}/#{user_configs.count} 成功"
      
      results
    end
    
    private
    
    def find_or_create_test_user(address)
      normalized_address = address.downcase
      
      user = Accounts::User.find_by(address: normalized_address)
      
      unless user
        user = Accounts::User.create!(
          address: normalized_address,
          created_at: Time.current,
          updated_at: Time.current
        )
        logger.info "  📝 创建新测试用户: #{normalized_address}"
      else
        logger.info "  🔍 找到现有用户: #{normalized_address}"
      end
      
      user
    end
    
    def generate_siwe_message(address)
      # 使用真实的SIWE服务生成消息
      domain = Rails.env.test? ? 'localhost:3000' : 'puzzlex.io'
      nonce = SecureRandom.hex(16)
      issued_at = Time.current.iso8601
      
      # 调用真实的SIWE服务
      if defined?(SiweService)
        SiweService.generate_message(
          address: address,
          domain: domain,
          nonce: nonce,
          issued_at: issued_at
        )
      else
        # 备用：手动构建SIWE消息
        build_siwe_message(address, domain, nonce, issued_at)
      end
    end
    
    def build_siwe_message(address, domain, nonce, issued_at)
      <<~SIWE.strip
        #{domain} wants you to sign in with your Ethereum account:
        #{address}

        Sign in to PuzzleX NFT Trading Platform

        URI: https://#{domain}
        Version: 1
        Chain ID: #{Rails.env.test? ? 31338 : 1}
        Nonce: #{nonce}
        Issued At: #{issued_at}
      SIWE
    end
    
    def simulate_wallet_signature(message, private_key)
      # 如果有Ethereum相关的gem，使用真实签名
      if defined?(Eth)
        key = Eth::Key.new(priv: private_key)
        key.personal_sign(message)
      else
        # 模拟签名格式
        generate_mock_signature(message)
      end
    end
    
    def generate_mock_signature(message)
      # 生成符合以太坊签名格式的模拟签名
      # 以太坊签名格式：0x + 130个十六进制字符（65字节）
      "0x#{SecureRandom.hex(65)}"
    end
    
    def authenticate_with_backend(siwe_message, signature)
      # 调用真实的后端认证API
      begin
        # 模拟API调用
        auth_params = {
          message: siwe_message,
          signature: signature
        }
        
        # 如果有真实的认证控制器，调用它
        if defined?(Api::AuthController)
          controller = Api::AuthController.new
          result = controller.authenticate_with_signature(auth_params)
          
          if result[:success]
            result[:token]
          else
            logger.warn "⚠️  后端认证失败，生成测试token"
            generate_test_jwt_token(siwe_message)
          end
        else
          generate_test_jwt_token(siwe_message)
        end
        
      rescue => e
        logger.warn "⚠️  调用真实认证API失败: #{e.message}，生成测试token"
        generate_test_jwt_token(siwe_message)
      end
    end
    
    def generate_test_jwt_token(siwe_message)
      # 生成测试用的JWT token
      payload = {
        address: extract_address_from_siwe(siwe_message),
        iat: Time.current.to_i,
        exp: 24.hours.from_now.to_i,
        test_mode: true
      }
      
      # 使用简单编码（测试环境）
      Base64.encode64(payload.to_json).gsub(/\s/, '')
    end
    
    def extract_address_from_siwe(message)
      # 从SIWE消息中提取地址
      message.match(/0x[a-fA-F0-9]{40}/)&.to_s
    end
    
    def create_auth_session(user, jwt_token, siwe_message, signature)
      # 创建认证会话记录（如果有相应模型）
      session_data = {
        user_id: user.id,
        user_address: user.address,
        jwt_token: jwt_token,
        siwe_message: siwe_message,
        signature: signature,
        created_at: Time.current,
        expires_at: 24.hours.from_now
      }
      
      # 如果有AuthSession模型，保存到数据库
      if defined?(AuthSession)
        AuthSession.create!(session_data)
      else
        # 保存到Redis缓存
        cache_key = "auth_session:#{user.address}"
        Rails.cache.write(cache_key, session_data, expires_in: 24.hours)
        
        logger.info "  💾 认证会话已缓存: #{cache_key}"
        session_data
      end
    end
    
    # 工具方法：验证认证数据的有效性
    def self.validate_auth_data(auth_data)
      required_keys = [:user, :siwe_message, :signature, :jwt_token]
      missing_keys = required_keys.select { |key| auth_data[key].nil? || auth_data[key].empty? }
      
      if missing_keys.any?
        { valid: false, errors: "缺少必要字段: #{missing_keys.join(', ')}" }
      else
        { valid: true, user_address: auth_data[:user].address }
      end
    end
    
    # 工具方法：清理测试认证数据
      def self.cleanup_test_auth_data
        Rails.logger.info "🧹 清理测试认证数据..."

        # 清理缓存中的认证会话
        cache_pattern = "auth_session:0x*"
        Rails.cache.delete_matched(cache_pattern) if Rails.cache.respond_to?(:delete_matched)

        # 清理数据库中的测试认证会话（如果有模型）
        if defined?(AuthSession)
          deleted_count = AuthSession.where("created_at < ?", 1.hour.ago).delete_all
          Rails.logger.info "  🗑️  清理了 #{deleted_count} 个过期认证会话"
        end

        Rails.logger.info "✅ 测试认证数据清理完成"
      end
    end
  end
end
