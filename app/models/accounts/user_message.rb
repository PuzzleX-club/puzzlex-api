# frozen_string_literal: true

module Accounts
  # 用户消息模型
  # 永久保留消息，支持多项目扩展
  class UserMessage < ApplicationRecord
    # ============================================
    # 消息类型枚举
    # ============================================
    enum message_type: {
      order_filled: 'order_filled',           # 订单成交
      order_partially_filled: 'order_partially_filled', # 部分成交
      order_cancelled: 'order_cancelled',     # 订单取消
      system_alert: 'system_alert'            # 系统警告
    }

    # ============================================
    # 消息状态枚举
    # ============================================
    enum status: {
      unread: 0,    # 未读
      read: 1,      # 已读
      archived: 2   # 已归档
    }

    # ============================================
    # 优先级枚举
    # ============================================
    enum priority: {
      normal: 0,    # 普通
      important: 1, # 重要
      urgent: 2     # 紧急
    }

    # ============================================
    # 关联
    # ============================================
    belongs_to :user, foreign_key: :user_id, class_name: 'Accounts::User'

    # ============================================
    # 验证
    # ============================================
    validates :user_id, presence: true
    validates :project, presence: true
    validates :message_type, presence: true
    validates :title, presence: true
    validates :content, presence: true

    # ============================================
    # 作用域
    # ============================================

    # 按项目和用户查询
    scope :by_project, ->(project) { where(project: project) }
    scope :for_user, ->(user_id) { where(user_id: user_id) }

    # 按项目和用户查询
    scope :by_user_and_project, ->(user_id, project) { where(user_id: user_id, project: project) }

    # 按状态查询
    scope :unread, -> { where(status: :unread) }
    scope :read, -> { where(status: :read) }
    scope :archived, -> { where(status: :archived) }

    # 按消息类型查询
    scope :by_type, ->(type) { where(message_type: type) }

    # 未读消息计数（支持项目和用户过滤）
    scope :unread_count, ->(user_id, project = nil) do
      query = where(user_id: user_id, status: :unread)
      query = query.where(project: project) if project.present?
      query.count
    end

    # 按创建时间排序（默认降序）
    default_scope { order(created_at: :desc) }

    # ============================================
    # 辅助方法
    # ============================================

    # 标记为已读
    def mark_as_read!
      return if read?

      update!(status: :read, read_at: Time.current)
    end

    # 检查是否已读
    def read?
      status == 'read'
    end

    # 获取附加数据（兼容历史字符串）
    def data
      raw_data = read_attribute(:data)
      raw_data.is_a?(String) ? JSON.parse(raw_data) : raw_data
    end

    # 设置附加数据（直接写入 JSONB）
    def data=(val)
      write_attribute(:data, val)
    end

    # ============================================
    # 类方法
    # ============================================

    # 创建消息
    def self.create_message(user_id, project, message_type, title, content, data = {}, priority: :normal)
      create!(
        user_id: user_id,
        project: project,
        message_type: message_type,
        title: title,
        content: content,
        data: data,
        priority: priority,
        status: :unread
      )
    end

    # 获取用户消息列表（分页）
    def self.messages_for_user(user_id, project = nil, options = {})
      query = where(user_id: user_id)
      query = query.where(project: project) if project.present?

      # 状态过滤
      if options[:status].present?
        query = query.where(status: options[:status])
      end

      # 消息类型过滤
      if options[:message_type].present?
        query = query.where(message_type: options[:message_type])
      end

      # 分页（避免依赖 kaminari）
      page = (options[:page] || 1).to_i
      per_page = (options[:per_page] || 20).to_i
      page = 1 if page <= 0
      per_page = 20 if per_page <= 0

      query.limit(per_page).offset((page - 1) * per_page)
    end

    # 获取未读消息数量
    def self.unread_messages_count(user_id, project = nil)
      query = where(user_id: user_id, status: :unread)
      query = query.where(project: project) if project.present?
      query.count
    end

    # 获取用户消息数量（用于分页）
    def self.count_for_user(user_id, project = nil, options = {})
      query = where(user_id: user_id)
      query = query.where(project: project) if project.present?

      if options[:status].present?
        query = query.where(status: options[:status])
      end

      if options[:message_type].present?
        query = query.where(message_type: options[:message_type])
      end

      query.count
    end

    # 标记所有消息为已读
    def self.mark_all_as_read(user_id, project = nil, message_type = nil)
      query = where(user_id: user_id, status: :unread)
      query = query.where(project: project) if project.present?
      query = query.where(message_type: message_type) if message_type.present?

      query.update_all(status: :read, read_at: Time.current)
    end

    # 标记单条消息为已读
    def self.mark_as_read(message_id, user_id)
      where(id: message_id, user_id: user_id).update_all(status: :read, read_at: Time.current)
    end
  end
end
