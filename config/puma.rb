# This configuration file will be evaluated by Puma. The top-level methods that
# are invoked here are part of Puma's configuration DSL. For more information
# about methods provided by the DSL, see https://puma.io/puma/Puma/DSL.html.

# Puma can serve each request in a thread from an internal thread pool.
# The `threads` method setting takes two numbers: a minimum and maximum.
# Any libraries that use thread pools should be configured to match
# the maximum value specified for Puma.
max_threads_count = ENV.fetch("RAILS_MAX_THREADS") { 16 }
min_threads_count = ENV.fetch("RAILS_MIN_THREADS") { [8, max_threads_count].min }
threads min_threads_count, max_threads_count

# Specifies that the worker count should equal the number of processors in production.
if ENV["RAILS_ENV"] == "production"
  worker_count = Integer(ENV.fetch("WEB_CONCURRENCY") { 2 })
  workers worker_count if worker_count > 0
end

require 'fileutils'

# 判断是否在 Kubernetes 环境中
# Kubernetes 会自动设置 KUBERNETES_SERVICE_HOST 环境变量
# 或者可以通过 USE_TCP_PORT 环境变量明确指定使用 TCP 端口
use_tcp_port = ENV["USE_TCP_PORT"] == "true" || !ENV["KUBERNETES_SERVICE_HOST"].nil?

if use_tcp_port
  # Kubernetes 环境：使用 TCP 端口（Kubernetes Service 需要通过 TCP 访问）
  port ENV.fetch("PORT") { 3000 }
else
  # 传统部署环境：使用 Unix socket（需要 Nginx 反向代理）
  app_dir = File.expand_path('../..',__FILE__)
  shared_dir = "#{app_dir}/shared"
  sockets_dir = "#{shared_dir}/sockets"
  FileUtils.mkdir_p(sockets_dir)
  bind "unix://#{sockets_dir}/puma.sock"
  # 设置logging
  stdout_redirect "#{shared_dir}/log/puma.stdout.log","#{shared_dir}/log/puma.stderr.log",true
  # 设置PID和state
  pidfile "#{shared_dir}/pid/puma.pid"
  state_path "#{shared_dir}/pid/puma.state"
  activate_control_app
end

# Specifies the `worker_timeout` threshold that Puma will use to wait before
# terminating a worker in development environments.
worker_timeout 3600 if ENV.fetch("RAILS_ENV", "development") == "development"

# 非生产环境默认使用 TCP 端口（如果还没有设置）
unless ENV["RAILS_ENV"] == "production" || use_tcp_port
  port ENV.fetch("PORT") { 3000 }
end

# Specifies the `environment` that Puma will run in.
environment ENV.fetch("RAILS_ENV") { "development" }

# Specifies the `pidfile` that Puma will use.
# pidfile ENV.fetch("PIDFILE") { "tmp/pids/server.pid" }

# Allow puma to be restarted by `bin/rails restart` command.
plugin :tmp_restart

preload_app!

on_worker_boot do
  require 'active_record'
  rails_env = ENV.fetch("RAILS_ENV") { "development" }
  puts "[PUMA] on_worker_boot starting..."
  # 1) 断开默认数据库连接并重连
  ActiveRecord::Base.connection.disconnect! rescue ActiveRecord::ConnectionNotEstablished
  ActiveRecord::Base.establish_connection(Rails.application.config.database_configuration[rails_env])

  begin
  rescue => e
    puts "[PUMA] on_worker_boot error: #{e.message}"
    e.backtrace.each { |line| puts line }
  end

end
