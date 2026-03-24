# frozen_string_literal: true

module User
  # 用户消息服务
  # 提供消息的 CRUD 操作
  class MessageService
    class << self
      DEFAULT_PROJECT = Rails.application.config.x.project.default_key.freeze

      # 创建消息
      # @param user [Accounts::User] 用户对象
      # @param message_type [String] 消息类型
      # @param title [String] 消息标题
      # @param content [String] 消息内容
      # @param data [Hash] 附加数据
      # @param project [String] 项目标识
      # @param priority [Symbol] 优先级 (:normal, :important, :urgent)
      # @return [Accounts::UserMessage] 创建的消息记录
      def create_message(user, message_type, title, content, data = {}, project = DEFAULT_PROJECT, priority: :normal)
        Accounts::UserMessage.create_message(
          user.id,
          project,
          message_type,
          title,
          content,
          data,
          priority: priority
        )
      end

      # 获取消息列表（分页）
      # @param user [Accounts::User] 用户对象
      # @param options [Hash] 查询选项
      # @option options [String] :project 项目标识
      # @option options [String] :status 状态过滤
      # @option options [String] :message_type 消息类型过滤
      # @option options [Integer] :page 页码
      # @option options [Integer] :per_page 每页数量
      # @return [Accounts::UserMessage::ActiveRecord_Relation] 消息关系
      def list_messages(user, options = {})
        Accounts::UserMessage.messages_for_user(
          user.id,
          options[:project] || DEFAULT_PROJECT,
          options.slice(:status, :message_type, :page, :per_page)
        )
      end

      # 统计消息数量（用于分页）
      def count_messages(user, options = {})
        Accounts::UserMessage.count_for_user(
          user.id,
          options[:project] || DEFAULT_PROJECT,
          options.slice(:status, :message_type)
        )
      end

      # 获取未读消息数量
      # @param user [Accounts::User] 用户对象
      # @param project [String] 项目标识
      # @return [Integer] 未读消息数量
      def unread_count(user, project = DEFAULT_PROJECT)
        Accounts::UserMessage.unread_messages_count(user.id, project)
      end

      # 标记消息为已读
      # @param message_id [Integer] 消息 ID
      # @param user [Accounts::User] 用户对象
      # @return [Boolean] 是否成功
      def mark_as_read(message_id, user)
        Accounts::UserMessage.mark_as_read(message_id, user.id) > 0
      end

      # 标记所有消息为已读
      # @param user [Accounts::User] 用户对象
      # @param project [String] 项目标识
      # @param message_type [String] 消息类型（可选）
      # @return [Integer] 更新的记录数
      def mark_all_as_read(user, project = DEFAULT_PROJECT, message_type = nil)
        Accounts::UserMessage.mark_all_as_read(user.id, project, message_type)
      end

      # 获取单条消息
      # @param message_id [Integer] 消息 ID
      # @param user [Accounts::User] 用户对象
      # @return [Accounts::UserMessage, nil] 消息记录
      def get_message(message_id, user)
        Accounts::UserMessage.find_by(id: message_id, user_id: user.id)
      end

      # 归档消息
      # @param message_id [Integer] 消息 ID
      # @param user [Accounts::User] 用户对象
      # @return [Boolean] 是否成功
      def archive_message(message_id, user)
        message = get_message(message_id, user)
        return false unless message

        message.update!(status: :archived)
        true
      end

      # 批量归档消息
      # @param user [Accounts::User] 用户对象
      # @param project [String] 项目标识
      # @param message_type [String] 消息类型（可选）
      # @return [Integer] 更新的记录数
      def archive_all(user, project = DEFAULT_PROJECT, message_type = nil)
        Accounts::UserMessage.where(
          user_id: user.id,
          project: project,
          status: [:unread, :read]
        ).update_all(status: :archived)
      end

      # 删除消息
      # @param message_id [Integer] 消息 ID
      # @param user [Accounts::User] 用户对象
      # @return [Boolean] 是否成功
      def delete_message(message_id, user)
        Accounts::UserMessage.where(id: message_id, user_id: user.id).delete_all > 0
      end

      # 清空用户所有消息
      # @param user [Accounts::User] 用户对象
      # @param project [String] 项目标识
      # @return [Integer] 删除的记录数
      def clear_all(user, project = DEFAULT_PROJECT)
        Accounts::UserMessage.by_user_and_project(user.id, project).delete_all
      end
    end
  end
end
