# frozen_string_literal: true

# 用户消息控制器
# 提供消息查询和状态管理
class Client::User::MessagesController < ::Client::ProtectedController
  before_action :set_project

  # 获取消息列表
  # GET /api/user/messages
  def index
    options = {
      status: params[:status],
      message_type: params[:message_type],
      page: params[:page] || 1,
      per_page: params[:per_page] || 20
    }

    messages = User::MessageService.list_messages(current_user, options.merge(project: @project))
    total_count = User::MessageService.count_messages(current_user, options.merge(project: @project))
    per_page = (options[:per_page] || 20).to_i
    per_page = 20 if per_page <= 0
    current_page = (options[:page] || 1).to_i
    current_page = 1 if current_page <= 0
    total_pages = (total_count.to_f / per_page).ceil

    render_success({
      items: messages.map { |msg| message_response(msg) },
      pagination: {
        current_page: current_page,
        total_pages: total_pages,
        total_count: total_count,
        per_page: per_page
      }
    })
  end

  # 获取消息详情
  # GET /api/user/messages/:id
  def show
    message = User::MessageService.get_message(params[:id], current_user)

    if message.nil?
      return render_error('消息不存在', :not_found)
    end

    render_success(message_response(message))
  end

  # 标记消息已读
  # PUT /api/user/messages/:id/read
  def mark_read
    message_id = params[:id]

    if message_id.blank?
      return render_error('消息ID不能为空', :bad_request)
    end

    success = User::MessageService.mark_as_read(message_id, current_user)

    if success
      render_success(nil, '标记已读成功')
    else
      render_error('消息不存在或已被删除', :not_found)
    end
  end

  # 标记所有消息已读
  # PUT /api/user/messages/read_all
  def mark_all_read
    message_type = params[:message_type]
    count = User::MessageService.mark_all_as_read(current_user, @project, message_type)

    render_success({ count: count }, "已标记 #{count} 条消息为已读")
  end

  # 获取未读消息数量
  # GET /api/user/messages/unread_count
  def unread_count
    count = User::MessageService.unread_count(current_user, @project)
    render_success({ count: count })
  end

  # 归档消息
  # PUT /api/user/messages/:id/archive
  def archive
    message_id = params[:id]

    if message_id.blank?
      return render_error('消息ID不能为空', :bad_request)
    end

    success = User::MessageService.archive_message(message_id, current_user)

    if success
      render_success(nil, '归档成功')
    else
      render_error('消息不存在', :not_found)
    end
  end

  # 删除消息
  # DELETE /api/user/messages/:id
  def destroy
    message_id = params[:id]

    if message_id.blank?
      return render_error('消息ID不能为空', :bad_request)
    end

    success = User::MessageService.delete_message(message_id, current_user)

    if success
      render_success(nil, '删除成功')
    else
      render_error('消息不存在', :not_found)
    end
  end

  private

  def set_project
    @project = params[:project]
    return if @project.present?

    @project = Rails.application.config.x.project.default_key
    Rails.logger.info "[Client::User::MessagesController] ⚠️ 未提供 project，降级使用默认值: #{@project}"
  end

  def message_response(msg)
    {
      id: msg.id,
      message_type: msg.message_type,
      title: msg.title,
      content: msg.content,
      data: msg.data,
      priority: msg.priority,
      status: msg.status,
      read_at: msg.read_at,
      created_at: msg.created_at
    }
  end
end
