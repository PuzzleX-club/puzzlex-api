# frozen_string_literal: true

module Accounts
  # 用户偏好设置模型
  # 每个 key 一行，支持多项目扩展
  class UserPreference < ApplicationRecord
    # ============================================
    # 关联
    # ============================================
    belongs_to :user, foreign_key: :user_id, class_name: 'Accounts::User'

    # ============================================
    # 验证
    # ============================================
    validates :user_id, presence: true
    validates :project, presence: true
    validates :key, presence: true

    # ============================================
    # 作用域
    # ============================================

    # 按项目和用户查询
    scope :by_project, ->(project) { where(project: project) }
    scope :for_user, ->(user_id) { where(user_id: user_id) }

    # 按项目和用户查询
    scope :by_user_and_project, ->(user_id, project) { where(user_id: user_id, project: project) }

    # ============================================
    # 辅助方法
    # ============================================

    # 获取偏好值（兼容历史字符串）
    def value
      raw_value = read_attribute(:value)
      raw_value.is_a?(String) ? JSON.parse(raw_value) : raw_value
    end

    # 设置偏好值（直接写入 JSONB）
    def value=(val)
      write_attribute(:value, val)
    end

    # ============================================
    # 类方法
    # ============================================

    # 获取单个偏好值
    def self.get_preference(user_id, project, key)
      pref = find_by(user_id: user_id, project: project, key: key)
      pref&.value
    end

    # 设置单个偏好值
    def self.set_preference(user_id, project, key, value, version: 1)
      pref = find_or_initialize_by(user_id: user_id, project: project, key: key)
      pref.value = value
      pref.version = version
      pref.save!
      pref
    end

    # 批量获取用户指定项目的所有偏好
    def self.preferences_for_user(user_id, project)
      where(user_id: user_id, project: project).each_with_object({}) do |pref, hash|
        hash[pref.key] = pref.value
      end
    end

    # 批量设置偏好
    def self.batch_set_preferences(user_id, project, preferences_hash)
      transaction do
        preferences_hash.each do |key, value|
          set_preference(user_id, project, key, value)
        end
      end
    end

    # 删除偏好
    def self.delete_preference(user_id, project, key)
      where(user_id: user_id, project: project, key: key).delete_all
    end
  end
end
