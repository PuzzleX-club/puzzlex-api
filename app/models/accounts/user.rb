module Accounts
  class User < ApplicationRecord
    # ============================================
    # 权限级别枚举
    # ============================================
    # 定义用户权限级别，用于管理后台访问控制
    enum admin_level: {
      user: 0,        # 普通用户
      admin: 1,       # 管理员
      super_admin: 2  # 超级管理员
    }

    # ============================================
    # 关联
    # ============================================
    has_many :user_favorite_items, dependent: :destroy
    has_many :user_preferences, dependent: :destroy
    has_many :user_messages, dependent: :destroy

    # ============================================
    # 验证
    # ============================================
    # 简单的验证：地址必填、唯一（不区分大小写）
    validates :address, presence: true, uniqueness: { case_sensitive: false }

    # ============================================
    # 权限检查方法
    # ============================================

    # 是否是管理员（包含 admin 和 super_admin）
    def admin?
      admin_level.in?(%w[admin super_admin])
    end

    # 是否是超级管理员
    def super_admin?
      admin_level == 'super_admin'
    end

    # ============================================
    # Callbacks
    # ============================================

    # 自动转换地址为小写
    before_save :downcase_address

    private

    def downcase_address
      self.address = address.downcase
    end
  end
end
