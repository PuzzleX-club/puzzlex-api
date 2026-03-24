# frozen_string_literal: true

module Infrastructure
  # 轻量级事件总线
  # 使用观察者模式实现事件驱动架构，支持同步和异步事件处理
  class EventBus
    class << self
      # 注册事件监听器
      # @param event_name [String, Symbol] 事件名称
      # @param listener [Object, Proc] 监听器对象或Proc
      # @param method_name [Symbol] 监听器方法名（当listener是对象时）
      # @param async [Boolean] 是否异步处理
      def subscribe(event_name, listener = nil, method_name: :call, async: false, &block)
        listener = block if block_given?

        raise ArgumentError, "Listener must be provided" unless listener

        subscribers[event_name.to_s] ||= []
        subscribers[event_name.to_s] << {
          listener: listener,
          method_name: method_name,
          async: async
        }

        Rails.logger.debug "[Infrastructure::EventBus] Subscribed to '#{event_name}' (async: #{async})"
      end

      # 发布事件
      # @param event_name [String, Symbol] 事件名称
      # @param data [Hash] 事件数据
      # @param metadata [Hash] 事件元数据
      def publish(event_name, data = {}, metadata = {})
        event = create_event(event_name, data, metadata)

        Rails.logger.info "[Infrastructure::EventBus] Publishing event '#{event_name}' with data: #{data.keys}"

        event_subscribers = subscribers[event_name.to_s] || []

        return if event_subscribers.empty?

        # 分别处理同步和异步订阅者
        sync_subscribers = event_subscribers.reject { |sub| sub[:async] }
        async_subscribers = event_subscribers.select { |sub| sub[:async] }

        # 同步处理
        process_sync_subscribers(event, sync_subscribers)

        # 异步处理
        process_async_subscribers(event, async_subscribers) unless async_subscribers.empty?

        Rails.logger.debug "[Infrastructure::EventBus] Event '#{event_name}' published to #{event_subscribers.size} subscribers"

        event
      end

      # 取消订阅
      # @param event_name [String, Symbol] 事件名称
      # @param listener [Object] 监听器对象
      def unsubscribe(event_name, listener)
        return unless subscribers[event_name.to_s]

        subscribers[event_name.to_s].reject! { |sub| sub[:listener] == listener }
        subscribers.delete(event_name.to_s) if subscribers[event_name.to_s].empty?

        Rails.logger.debug "[Infrastructure::EventBus] Unsubscribed from '#{event_name}'"
      end

      # 清除所有订阅者（主要用于测试）
      def clear_all_subscribers
        @subscribers = {}
        Rails.logger.debug "[Infrastructure::EventBus] Cleared all subscribers"
      end

      # 获取事件统计信息
      def stats
        {
          total_events: subscribers.keys.size,
          total_subscribers: subscribers.values.flatten.size,
          events: subscribers.transform_values { |subs| subs.size }
        }
      end

      # 获取订阅者数量
      def subscriber_count
        subscribers.values.flatten.size
      end

      # 获取调试订阅信息
      def debug_subscriptions
        subscribers.transform_values do |subs|
          subs.map do |sub|
            {
              listener_class: sub[:listener].class.name,
              method_name: sub[:method_name],
              async: sub[:async]
            }
          end
        end
      end

      # 单例模式支持
      def instance
        self
      end

      private

      def subscribers
        @subscribers ||= {}
      end

      def create_event(event_name, data, metadata)
        Event.new(
          name: event_name.to_s,
          data: data,
          metadata: metadata.merge(
            published_at: Time.current,
            event_id: SecureRandom.uuid
          )
        )
      end

      def process_sync_subscribers(event, sync_subscribers)
        sync_subscribers.each do |subscriber|
          begin
            call_subscriber(subscriber, event)
          rescue => e
            handle_subscriber_error(e, event, subscriber)
          end
        end
      end

      def process_async_subscribers(event, async_subscribers)
        # 转换subscribers数据为Worker期望的格式
        subscribers_data = async_subscribers.map do |subscriber|
          {
            'listener_class' => subscriber[:listener].class.name,
            'method_name' => subscriber[:method_name].to_s
          }
        end

        Jobs::Indexer::EventProcessingWorker.perform_async(event.to_h.deep_stringify_keys, subscribers_data)
      end

      def call_subscriber(subscriber, event)
        listener = subscriber[:listener]
        method_name = subscriber[:method_name]

        if listener.is_a?(Proc)
          listener.call(event)
        elsif listener.respond_to?(method_name)
          listener.public_send(method_name, event)
        else
          raise ArgumentError, "Listener does not respond to #{method_name}"
        end
      end

      def handle_subscriber_error(error, event, subscriber)
        Rails.logger.error "[Infrastructure::EventBus] Error processing event '#{event.name}': #{error.message}"
        Rails.logger.error error.backtrace.join("\n") if Rails.env.development?

        # 可以在这里添加错误通知逻辑
        # ErrorNotificationService.notify(error, event, subscriber)
      end
    end

    # 事件对象
    class Event
      attr_reader :name, :data, :metadata
    
      def initialize(name:, data:, metadata:)
        @name = name
        @data = data
        @metadata = metadata
      end
    
      def event_id
        metadata[:event_id]
      end
    
      def published_at
        metadata[:published_at]
      end
    
      def to_h
        {
          name: name,
          data: data,
          metadata: metadata
        }
      end
    
      def to_json(*args)
        to_h.to_json(*args)
      end
    end
  end
end
