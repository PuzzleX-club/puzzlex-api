# frozen_string_literal: true

# SimpleCov 必须在任何应用代码加载之前启动
# 仅在 CI 环境或明确请求时启用覆盖率

if ENV['CI'] || ENV['COVERAGE']
  require 'simplecov'
  require 'simplecov-json'

  SimpleCov.start 'rails' do
    # 使用固定command_name（每次运行会覆盖上次结果，避免累积）
    # 参见：ADR-078 SimpleCov覆盖率累积问题解决方案
    command_name 'RSpec'

    # 格式化器配置 - 同时生成 HTML 和 JSON 报告
    SimpleCov.formatters = SimpleCov::Formatter::MultiFormatter.new([
      SimpleCov::Formatter::HTMLFormatter,
      SimpleCov::Formatter::JSONFormatter
    ])

    # 覆盖率输出目录
    coverage_dir 'coverage'

    # 排除目录 - 不计入覆盖率统计
    add_filter '/spec/'
    add_filter '/config/'
    add_filter '/db/'
    add_filter '/vendor/'
    add_filter '/lib/tasks/'
    add_filter '/app/admin/' # ActiveAdmin 生成的代码

    # 分组配置 - 便于在报告中查看各模块覆盖率
    add_group 'Models', 'app/models'
    add_group 'Controllers', 'app/controllers'
    add_group 'Services', 'app/services'
    add_group 'Jobs', 'app/sidekiq'
    add_group 'Channels', 'app/channels'
    add_group 'Helpers', 'app/helpers'
    add_group 'Libraries', 'lib'

    # 禁用合并（使用覆盖模式）
    # 每次运行前需要手动清理 coverage/ 目录
    use_merging false

    # 最低覆盖率阈值 - 设为 0 表示仅报告不阻塞
    # 可以逐步提高这个值
    minimum_coverage line: 0
    minimum_coverage_by_file line: 0

    # 跟踪的文件范围
    track_files '{app,lib}/**/*.rb'

    # 启用分支覆盖（Rails 7+）
    enable_coverage :branch
    primary_coverage :line
  end

  puts '[SimpleCov] 覆盖率追踪已启用 - 报告将生成到 coverage/ 目录'
end
