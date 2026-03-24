# frozen_string_literal: true

module Jobs
  module Orders
    class RevalidationJob
      include Sidekiq::Job
      sidekiq_options queue: :default, retry: false

      def perform(order_id, user_id, options = {})
        opts = options.is_a?(Hash) ? options.with_indifferent_access : {}
        request_id = opts[:request_id]
        actor_address = opts[:actor_address]
        project = opts[:project].presence || Rails.application.config.x.project.default_key

        order = Trading::Order.find_by(id: order_id)
        user = Accounts::User.find_by(id: user_id)
        return unless order && user

        result = run_revalidation(order, actor_address: actor_address)
        metadata_info = build_metadata_info(order, user, result, request_id)

        persist_revalidation_metadata(order, metadata_info)
        send_user_message(user, metadata_info, project)
      rescue => e
        fallback_info = build_error_metadata(order_id, request_id, e)
        persist_revalidation_metadata_by_id(order_id, fallback_info)
        send_error_message(user_id, fallback_info, project)
      end

      private

      def run_revalidation(order, actor_address: nil)
        Orders::OrderRevalidationService.new(order, actor: actor_address).call
      end

      def build_metadata_info(order, user, result, request_id)
        status = result[:status]
        data = result[:data] || {}
        order_hash = data[:order_hash] || order.order_hash
        data = data.merge(order_hash: order_hash)

        result_key = case status
                     when :completed
                       data[:validation_passed] ? 'passed' : 'failed'
                     when :limit
                       'limit'
                     when :locked
                       'locked'
                     when :invalid
                       'invalid'
                     else
                       'failed'
                     end

        locale = resolve_locale(user)
        message = build_message(locale, result_key, data)

        {
          order_hash: order_hash,
          request_id: request_id,
          result: result_key,
          message: message,
          error: data[:failure_reason],
          status_before: data[:status_before],
          status_after: data[:status_after],
          validation_passed: data[:validation_passed],
          remaining_attempts: data[:remaining_attempts],
          max_attempts: data[:max_attempts],
          locked: data[:locked],
          updated_at: Time.current.iso8601
        }
      end

      def build_error_metadata(order_id, request_id, error)
        locale = I18n.locale.to_s
        message = locale.to_s.start_with?('en') ? 'Order revalidation failed due to system error.' : '订单重试失败：系统错误。'

        {
          request_id: request_id,
          result: 'error',
          message: message,
          error: error.message,
          order_id: order_id,
          updated_at: Time.current.iso8601
        }
      end

      def persist_revalidation_metadata(order, metadata_info)
        order.with_lock do
          metadata = order.metadata.is_a?(Hash) ? order.metadata.deep_dup : {}
          metadata['revalidation_last_result'] = metadata_info[:result]
          metadata['revalidation_last_message'] = metadata_info[:message]
          metadata['revalidation_last_error'] = metadata_info[:error]
          metadata['revalidation_last_at'] = metadata_info[:updated_at]
          metadata['revalidation_request_id'] = metadata_info[:request_id]
          metadata['revalidation_last_status_before'] = metadata_info[:status_before]
          metadata['revalidation_last_status_after'] = metadata_info[:status_after]
          metadata['revalidation_last_validation_passed'] = metadata_info[:validation_passed]
          metadata['revalidation_last_remaining_attempts'] = metadata_info[:remaining_attempts]
          metadata['revalidation_last_max_attempts'] = metadata_info[:max_attempts]
          metadata['revalidation_last_locked'] = metadata_info[:locked]
          order.update!(metadata: metadata)
        end
      end

      def persist_revalidation_metadata_by_id(order_id, metadata_info)
        order = Trading::Order.find_by(id: order_id)
        return unless order

        persist_revalidation_metadata(order, metadata_info)
      end

      def send_user_message(user, metadata_info, project)
        title, content = build_message_payload(user, metadata_info)
        User::MessageService.create_message(
          user,
          'system_alert',
          title,
          content,
          { order_hash: metadata_info[:order_hash], revalidation: metadata_info },
          project,
          priority: :normal
        )
      end

      def send_error_message(user_id, metadata_info, project)
        user = Accounts::User.find_by(id: user_id)
        return unless user

        title = metadata_info[:message]
        content = metadata_info[:message]
        User::MessageService.create_message(
          user,
          'system_alert',
          title,
          content,
          { revalidation: metadata_info },
          project,
          priority: :important
        )
      end

      def build_message_payload(user, metadata_info)
        locale = resolve_locale(user)
        base = metadata_info[:message]

        title = locale.start_with?('en') ? 'Order revalidation result' : '订单重试结果'
        [title, base]
      end

      def build_message(locale, result_key, data)
        order_hash = data[:order_hash].to_s
        short_hash = order_hash.present? ? "#{order_hash[0, 6]}...#{order_hash[-4, 4]}" : ''
        reason = data[:failure_reason].to_s

        if locale.to_s.start_with?('en')
          case result_key
          when 'passed'
            "Order restored. Revalidation passed. Order: #{short_hash}"
          when 'failed'
            reason_text = reason.empty? ? 'Reason unknown.' : "Reason: #{reason}"
            "Order revalidation failed. #{reason_text} Order: #{short_hash}"
          when 'limit'
            "Order revalidation blocked: max attempts reached. Order: #{short_hash}"
          when 'locked'
            "Order revalidation is already in progress. Order: #{short_hash}"
          when 'invalid'
            "Order status is not eligible for revalidation. Order: #{short_hash}"
          else
            "Order revalidation finished. Order: #{short_hash}"
          end
        else
          case result_key
          when 'passed'
            "订单已恢复：重试验证通过。订单：#{short_hash}"
          when 'failed'
            reason_text = reason.empty? ? '原因未知' : "原因：#{reason}"
            "订单重试失败：#{reason_text}。订单：#{short_hash}"
          when 'limit'
            "订单重试失败：已达到最大重试次数。订单：#{short_hash}"
          when 'locked'
            "订单重试处理中：已有重试任务在执行。订单：#{short_hash}"
          when 'invalid'
            "订单状态不支持重试。订单：#{short_hash}"
          else
            "订单重试已完成。订单：#{short_hash}"
          end
        end
      end

      def resolve_locale(user)
        return I18n.locale.to_s if user.nil?

        preference = User::PreferenceService.get_preference(user, 'locale', Rails.application.config.x.project.default_key)
        preference.presence || I18n.locale.to_s
      end
    end
  end
end
