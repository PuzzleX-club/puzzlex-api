# frozen_string_literal: true

module Jobs
  module Indexer
    # 异步事件处理 Worker
    # 处理 Infrastructure::EventBus 发布的异步事件
    class EventProcessingWorker
      include Sidekiq::Job

      sidekiq_options queue: :events, retry: 3

      def perform(event_data, subscribers_data)
        event = Infrastructure::EventBus::Event.new(
          name: event_data['name'],
          data: (event_data['data'] || {}).deep_symbolize_keys,
          metadata: (event_data['metadata'] || {}).deep_symbolize_keys
        )

        Rails.logger.info "[EventProcessing] Processing async event '#{event.name}' for #{subscribers_data.size} subscribers"

        subscribers_data.each do |subscriber_data|
          begin
            process_subscriber(event, subscriber_data)
          rescue => e
            Rails.logger.error "[EventProcessing] Error processing subscriber: #{e.message}"
            Rails.logger.error e.backtrace.join("\n")

            # 重新抛出错误以触发Sidekiq重试
            raise e
          end
        end

        Rails.logger.debug "[EventProcessing] Completed processing event '#{event.name}'"
      end

      private

      def process_subscriber(event, subscriber_data)
        listener_class_name = subscriber_data['listener_class']
        method_name = subscriber_data['method_name'] || 'call'

        # 重新实例化监听器类
        listener_class = listener_class_name.constantize
        listener = listener_class.new

        if listener.respond_to?(method_name)
          listener.public_send(method_name, event)
        else
          raise ArgumentError, "Listener #{listener_class_name} does not respond to #{method_name}"
        end
      end
    end
  end
end
