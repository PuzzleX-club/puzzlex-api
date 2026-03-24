# frozen_string_literal: true

require "faraday"

module Indexer
  module EventPipeline
    class Collector
      # 配置常量
      MAX_CONSECUTIVE_FAILURES = Rails.application.config.x.log_collector.max_consecutive_failures
      ERROR_BACKOFF_MAX = Rails.application.config.x.log_collector.error_backoff_max
      CATCHUP_THRESHOLD = Rails.application.config.x.log_collector.catchup_threshold

      class << self
        # 进程级单例限速器
        def rate_limiter
          @rate_limiter ||= RateLimiter.new
        end

        # 重置限速器（用于测试）
        def reset_rate_limiter!
          @rate_limiter = nil
        end
      end

      def initialize(subscriptions: Onchain::EventSubscription.all, rpc_url: Rails.application.config.x.blockchain.rpc_url)
        @subscriptions = subscriptions
        @rpc_url = rpc_url
        @connection = build_connection
        @election_service = Sidekiq::Election::Service
        @skipped_subscriptions = []
      end

      def run
        # 只有leader实例才执行RPC操作
        return unless should_run_as_leader?

        latest_block = fetch_latest_block
        return unless latest_block

        # 计算追赶模式 RPS
        adjust_rps_for_catchup(latest_block)

        each_subscription do |sub|
          # 在循环中也检查leader状态，防止中途失去leader权
          break unless @election_service.leader?
          collect_for_subscription(sub, latest_block)
        end

        # 记录跳过的订阅
        log_skipped_subscriptions if @skipped_subscriptions.any?

        cleanup_retention
      end

      def should_run_as_leader?
        if @election_service.leader?
          Rails.logger.debug "[EventCollector] Leader实例，执行数据收集"
          true
        else
          leader_status = @election_service.status
          Rails.logger.info "[EventCollector] 非Leader实例，跳过数据收集。当前Leader: #{leader_status[:token]}"
          false
        end
      end

      private

      def build_connection
        # 移除 Faraday 内置重试，由 Collector 统一控制退避策略
        Faraday.new(url: @rpc_url) do |faraday|
          faraday.request :json
          faraday.response :json
          faraday.adapter Faraday.default_adapter
          faraday.options.timeout = 60
          faraday.options.open_timeout = 15
        end
      end

      def collect_for_subscription(subscription, latest_block)
        from_block = resolve_from_block(subscription)
        from_block = normalize_from_block(subscription, from_block, latest_block)
        return if from_block > latest_block

        consecutive_failures = 0

        while from_block <= latest_block
          # 检查leader状态
          break unless @election_service.leader?

          to_block = [from_block + subscription.block_window - 1, latest_block].min

          begin
            logs = fetch_logs(subscription, from_block, to_block)
            persist_logs(subscription, logs)
            Onchain::EventListenerStatus.update_status("collector:#{subscription.handler_key}", to_block, event_type: "collector:#{subscription.handler_key}")
            consecutive_failures = 0  # 成功重置
            from_block = to_block + 1
          rescue => e
            consecutive_failures += 1
            backoff = calculate_backoff(consecutive_failures)

            # 单行日志，便于 grep
            log_rate_limit_error(subscription.handler_key, consecutive_failures, backoff, e)

            if consecutive_failures >= MAX_CONSECUTIVE_FAILURES
              skip_subscription(subscription, consecutive_failures)
              break
            end

            sleep(backoff)
            # 不移动 from_block，重试当前区间
          end
        end
      end

      # 计算退避时间：快速升级 1→2→5→10→20→30
      def calculate_backoff(failures)
        backoff_steps = [1, 2, 5, 10, 20, 30]
        index = [failures - 1, backoff_steps.length - 1].min
        [backoff_steps[index], ERROR_BACKOFF_MAX].min
      end

      # 根据落后区块数动态调整 RPS
      def adjust_rps_for_catchup(latest_block)
        max_blocks_behind = 0

        each_subscription do |sub|
          from_block = resolve_from_block(sub)
          blocks_behind = latest_block - from_block
          max_blocks_behind = [max_blocks_behind, blocks_behind].max
        end

        new_rps = calculate_catchup_rps(max_blocks_behind)
        current_rps = self.class.rate_limiter.rps

        if new_rps != current_rps
          Rails.logger.info "[EventCollector] [CATCHUP] blocks_behind=#{max_blocks_behind} rps=#{current_rps}->#{new_rps}"
          self.class.rate_limiter.update_rps(new_rps)
        end
      end

      # 追赶模式分段提速：5→8→10 rps
      def calculate_catchup_rps(blocks_behind)
        base_rps = Rails.application.config.x.log_collector.rps
        catchup_rps = Rails.application.config.x.log_collector.catchup_rps

        case blocks_behind
        when 0..500 then base_rps          # 正常
        when 501..2000 then 8.0            # 轻度追赶
        else catchup_rps                   # 重度追赶
        end
      end

      def skip_subscription(subscription, failures)
        @skipped_subscriptions << {
          handler_key: subscription.handler_key,
          failures: failures
        }
        Rails.logger.error "[EventCollector] [SKIP] handler=#{subscription.handler_key} failures=#{failures} reason=max_consecutive_failures"

        # 记录到 Redis，下轮优先处理
        Sidekiq.redis { |c| c.sadd("indexer_event_collector:skipped", subscription.handler_key) }
      end

      def log_skipped_subscriptions
        return if @skipped_subscriptions.empty?

        handlers = @skipped_subscriptions.map { |s| s[:handler_key] }.join(",")
        Rails.logger.warn "[EventCollector] [SUMMARY] skipped_handlers=#{handlers} count=#{@skipped_subscriptions.size}"
      end

      def log_rate_limit_error(handler_key, failures, backoff, error)
        status = self.class.rate_limiter.status
        Rails.logger.warn "[EventCollector] [RATE_LIMIT] handler=#{handler_key} failures=#{failures} backoff=#{backoff}s rps=#{status[:rps]} tokens=#{status[:tokens]} error=#{error.class}"
      end

      def resolve_from_block(subscription)
        last = Onchain::EventListenerStatus.last_block(event_type: "collector:#{subscription.handler_key}")
        return subscription.start_block if last == "earliest"

        [last.to_i, subscription.start_block].max
      end

      # 本地链 reset 后，checkpoint 可能大于当前链高，导致采集器一直空跑。
      # 这种情况下自动回退到订阅 start_block，恢复事件采集。
      def normalize_from_block(subscription, from_block, latest_block)
        return from_block if latest_block.nil? || from_block <= latest_block

        fallback_block = subscription.start_block.to_i
        Rails.logger.warn(
          "[EventCollector] [CHAIN_ROLLBACK] handler=#{subscription.handler_key} " \
          "checkpoint=#{from_block} latest=#{latest_block} reset_to=#{fallback_block}"
        )

        Onchain::EventListenerStatus.update_status(
          "collector:#{subscription.handler_key}",
          fallback_block,
          event_type: "collector:#{subscription.handler_key}"
        )

        fallback_block
      end

      def fetch_latest_block
        @election_service.with_leader do
          response = perform_request("eth_blockNumber", [])
          response["result"] ? response["result"].to_i(16) : nil
        end
      rescue => e
        Rails.logger.error "[EventCollector] 获取最新区块失败: #{e.class} - #{e.message}"
        nil
      end

      def fetch_logs(subscription, from_block, to_block)
        @election_service.with_leader do
          params = [{
            fromBlock: "0x" + from_block.to_i.to_s(16),
            toBlock: "0x" + to_block.to_i.to_s(16),
            address: subscription.addresses,
            topics: subscription.topics
          }]

          response = perform_request("eth_getLogs", params)
          raise RuntimeError, response["error"].inspect if response["error"]

          response["result"] || []
        end
      end

      def perform_request(method, params)
        # 统一限速：每次 RPC 请求前获取令牌
        self.class.rate_limiter.acquire

        request_body = {
          jsonrpc: "2.0",
          method: method,
          params: params,
          id: rand(1..10000)
        }

        response = @connection.post do |req|
          req.headers["Content-Type"] = "application/json"
          req.body = request_body.to_json
        end

        response.body
      end

      def persist_logs(subscription, logs)
        logs.each do |log|
          begin
            event_name = subscription.event_name_for(log)
            record = Onchain::RawLog.create!(
              address: log["address"],
              event_name: event_name,
              topic0: (log["topics"] || [])[0],
              topics: log["topics"] || [],
              data: log["data"],
              block_number: hex_to_i(log["blockNumber"]),
              block_hash: log["blockHash"],
              transaction_hash: log["transactionHash"],
              log_index: hex_to_i(log["logIndex"]),
              transaction_index: hex_to_i(log["transactionIndex"]),
              block_timestamp: hex_to_i(log["timeStamp"]),
              decoded_payload: nil
            )

            lc = Onchain::LogConsumption.find_or_create_by!(raw_log: record, handler_key: subscription.handler_key) do |log_consumption|
              log_consumption.status = "pending"
              log_consumption.attempts = 0
            end

            # 同步顺序处理，保证事件按区块顺序执行
            if lc.status == "pending"
              Jobs::Indexer::EventConsumptionJob.new.perform(lc.id)
            end
          rescue ActiveRecord::RecordNotUnique
            # 已存在则跳过
          rescue => e
            Rails.logger.error "[EventCollector] 写入 raw_log 失败: #{e.class} - #{e.message}"
          end
        end
      end

      def record_retry(handler_key, from_block, to_block, error)
        Onchain::EventRetryRange.create!(
          event_type: "collector:#{handler_key}",
          from_block: from_block,
          to_block: to_block,
          attempts: 1,
          last_error: "#{error.class}: #{error.message}"
        )
      rescue => e
        Rails.logger.error "[EventCollector] 写 retry 失败: #{e.class} - #{e.message}"
      end

      def cleanup_retention
        retention_days = Rails.application.config.x.log_collector.retention_days
        return if retention_days.nil? || retention_days <= 0

        cutoff = retention_days.days.ago
        Onchain::RawLog.where("created_at < ?", cutoff).find_each do |raw|
          next unless raw.log_consumptions.where.not(status: "success").empty?
          raw.destroy!
        rescue => e
          Rails.logger.warn "[EventCollector] 清理 raw_log #{raw.id} 失败: #{e.class} - #{e.message}"
        end
      end

      def hex_to_i(value)
        return nil if value.nil?

        return value if value.is_a?(Integer)

        normalized_value = value.to_s
        if normalized_value.start_with?("0x")
          normalized_value.to_i(16)
        elsif normalized_value.match?(/\A[0-9a-fA-F]+\z/) && normalized_value.match?(/[a-fA-F]/)
          normalized_value.to_i(16)
        else
          normalized_value.to_i
        end
      end

      def each_subscription(&block)
        if @subscriptions.respond_to?(:find_each)
          @subscriptions.find_each(&block)
        else
          Array(@subscriptions).each(&block)
        end
      end
    end
  end
end
