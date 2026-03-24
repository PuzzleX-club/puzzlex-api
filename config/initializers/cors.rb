# config/initializers/cors.rb

Rails.application.config.middleware.insert_before 0, Rack::Cors do
  allow do
    # todo:限制端口会跨域错误，不知道原因
    # origins 'http://127.0.0.1:5173', 'http://127.0.0.1' # 前端的地址
    origins '*' # 前端的地址

    resource '*',
             headers: :any,
             methods: [:get, :post, :put, :patch, :delete, :options, :head]
             # credentials: true  # 如果需要发送认证信息，如 cookies
  end
end

# 在日志中输出 CORS 配置信息
Rails.logger.info "CORS Middleware Configured!"