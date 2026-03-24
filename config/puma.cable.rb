require "fileutils"

# ActionCable 通常需要大量并发连接，允许通过环境变量覆盖线程/worker
cable_max_threads = ENV.fetch('CABLE_MAX_THREADS', 32).to_i
cable_min_threads = ENV.fetch('CABLE_MIN_THREADS', [4, cable_max_threads].min).to_i
threads cable_min_threads, cable_max_threads

if ENV["CABLE_WEB_CONCURRENCY"]
  workers ENV.fetch("CABLE_WEB_CONCURRENCY").to_i
end

# 在 K8S 环境或者显式指定时，使用 TCP 端口监听；
# 传统部署（配合 Nginx）仍然使用 Unix Socket。
use_tcp_port =
  ENV["CABLE_USE_TCP_PORT"] == "true" ||
  ENV["USE_TCP_PORT"] == "true" ||
  !ENV["KUBERNETES_SERVICE_HOST"].nil?

if use_tcp_port
  # 和 Helm values 中的 containerPort / service.port 保持一致
  port ENV.fetch("CABLE_PORT") { ENV.fetch("PORT", 3000) }
else
  sockets_dir = File.join(shared_dir, "sockets")
  pid_dir     = File.join(shared_dir, "pid")

  FileUtils.mkdir_p(sockets_dir)
  FileUtils.mkdir_p(pid_dir)

  bind "unix://#{sockets_dir}/puma_cable.sock"

  stdout_redirect File.join(shared_dir, "log", "puma_cable.stdout.log"),
                  File.join(shared_dir, "log", "puma_cable.stderr.log"), true

  pidfile File.join(pid_dir, "puma_cable.pid")
  state_path File.join(pid_dir, "puma_cable.state")

  activate_control_app "unix:///tmp/puma-cable-control.sock"
end



preload_app!

on_worker_boot do
  next unless defined?(ActiveRecord::Base)

  ActiveRecord::Base.connection.disconnect! rescue ActiveRecord::ConnectionNotEstablished
  ActiveRecord::Base.establish_connection
end
