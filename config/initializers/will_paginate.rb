# frozen_string_literal: true

# WillPaginate 配置
# 确保 WillPaginate 正确加载到所有 ActiveRecord 模型中

require 'will_paginate/active_record'

# 确保 WillPaginate 扩展到 ActiveRecord::Relation
ActiveRecord::Base.send(:include, WillPaginate::ActiveRecord) unless ActiveRecord::Base.included_modules.include?(WillPaginate::ActiveRecord)

# 确保各域 ApplicationRecord 也加载 WillPaginate
Rails.application.config.after_initialize do
  [
    Trading::ApplicationRecord,
    Accounts::ApplicationRecord,
    Onchain::ApplicationRecord,
    Merkle::ApplicationRecord
  ].each do |klass|
    if defined?(klass)
      klass.send(:include, WillPaginate::ActiveRecord) unless klass.included_modules.include?(WillPaginate::ActiveRecord)
    end
  end
end
