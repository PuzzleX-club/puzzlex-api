class ExFrontendChannel < ApplicationCable::Channel
  def subscribed
    @topics = params[:topics] || []
    @already_unsubbed = false  # 标记，防止重复 unsub

    # 生成唯一的连接ID
    @connection_id = SecureRandom.uuid
    @subscription_manager = Realtime::SubscriptionManager.new(@connection_id)

    # 收集连接元数据
    connection_meta = {
      user_id: current_user&.id,
      user_address: current_user&.address,
      ip_address: request.remote_ip,
      user_agent: request.headers["User-Agent"],
      source: params[:source] || "unknown"
    }

    # 添加连接
    @subscription_manager.add_connection(@connection_id, connection_meta)

    # 添加订阅（使用新系统）
    @subscription_manager.add_subscription(@connection_id, @topics)

    # 兼容旧系统：同时更新计数器（过渡期）
    @topics.each do |topic|
      count = @subscription_manager.get_topic_subscriber_count(topic)
      Redis.current.set("sub_count:#{topic}", count)
      Redis.current.expire("sub_count:#{topic}", RuntimeCache::Keyspace::DEFAULT_SUB_COUNT_TTL)

      stream_from topic do |message|
        # 解析JSON字符串并传递
        if message.is_a?(String)
          parsed = JSON.parse(message) rescue nil
          transmit(parsed) if parsed
        else
          transmit(message)
        end
      end

      # 通用方法 => 检测 topic 类型并即时推送
      transmit_initial_data(topic)
    end

    logger.info "Successfully subscribed to ExFrontendChannel with connection_id: #{@connection_id}"

    # 向客户端发送带有 type 的确认消息，包含connection_id
    transmit({
      type: "subscription_confirmation",
      data: {
        message: "Subscription confirmed",
        connection_id: @connection_id,
        topics_count: @topics.size
      }
    })
  rescue => e
    logger.error "Subscription error: #{e.message}"
  end

  def update_topics(data)
    begin
      new_topics = data["topics"] || []

      # 使用SubscriptionManager更新订阅（自动计算差集）
      @subscription_manager.update_subscription(@connection_id, new_topics)

      # 停止所有流并重新订阅
      stop_all_streams
      new_topics.each do |topic|
        # 兼容旧系统：更新计数器
        count = @subscription_manager.get_topic_subscriber_count(topic)
        Redis.current.set("sub_count:#{topic}", count)
        Redis.current.expire("sub_count:#{topic}", RuntimeCache::Keyspace::DEFAULT_SUB_COUNT_TTL)

        stream_from topic do |message|
          # 解析JSON字符串并传递
          if message.is_a?(String)
            parsed = JSON.parse(message) rescue nil
            transmit(parsed) if parsed
          else
            transmit(message)
          end
        end

        # 通用方法 => 检测 topic 类型并即时推送
        transmit_initial_data(topic)
      end

      # 更新本地记录
      @topics = new_topics

      # 确认更新订阅的主题
      transmit({
        type: "topics_updated",
        data: {
          message: "Subscribed to new topics",
          topics: new_topics,
          connection_id: @connection_id
        }
      })
    rescue => e
      logger.error "Error in update_topics: #{e.message}"
      transmit({ type: "error", data: { message: "Failed to update topics", error: e.message } })
    end
  end

  def unsubscribed
    # 防止重复 unsub
    if @already_unsubbed
      logger.info "Skipping repeated unsubscribed call"
      return
    end
    @already_unsubbed = true

    logger.info "Unsubscribed from ExFrontendChannel, connection_id: #{@connection_id}"

    # 使用SubscriptionManager清理连接
    if @subscription_manager && @connection_id
      @subscription_manager.remove_connection(@connection_id)

      # 兼容旧系统：更新所有相关topic的计数器
      @topics.each do |topic|
        count = Realtime::SubscriptionManager.new.get_topic_subscriber_count(topic)
        key = "sub_count:#{topic}"
        final_count = [count, 0].max  # 确保不为负数
        if final_count > 0
          Redis.current.set(key, final_count)
          Redis.current.expire(key, RuntimeCache::Keyspace::DEFAULT_SUB_COUNT_TTL)
        else
          # 计数归零时删除键，无需等待TTL过期
          Redis.current.del(key)
        end
      end
    end

    stop_all_streams
  rescue => e
    logger.error "Unsubscribe error: #{e.message}"
  end

  # 处理客户端发送的消息
  def speak(data)
    # 广播消息给频道的所有订阅者
    ActionCable.server.broadcast("ExFrontendChannel", data)
  rescue => e
    logger.error "Speak error: #{e.message}"
  end

  # 检测topic类型，若需要即时推送 => 调用相应获取/组装逻辑再 transmit
  def transmit_initial_data(topic)
    # 1) DEPTH@ => 推送订单簿深度
    if topic.include?("@DEPTH_")
      market_id, limit_str = topic.split("@DEPTH_")
      limit = limit_str.to_i
      depth_data = MarketData::OrderBookDepth.new(market_id, limit).call
      transmit({
                 topic: topic, data: depth_data.merge(ts: Time.now.to_i)
               })

    # todo：完善其他需要即时推送的topic
    # 2) MARKET相关信息有即时推送功能，不需要订阅的时候推送
    # elsif topic.include?("MARKET")
    #   # 推送market信息等
    #   transmit({
    #              topic: topic, data: { market_info: "example_market_data" }.merge(ts: Time.now.to_i)
    #            })
    end
  end

  private

end
