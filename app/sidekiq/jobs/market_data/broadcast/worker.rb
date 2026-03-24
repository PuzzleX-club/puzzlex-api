# frozen_string_literal: true

module Jobs
  module MarketData
    module Broadcast
      # 统一广播Worker
      # 整合所有广播类Jobs，使用策略模式处理不同类型的广播
      class Worker
      include Sidekiq::Job

      # 支持的广播类型
      BROADCAST_TYPES = {
        'ticker_batch' => 'TickerBatchStrategy',     # ✅ 保留：MARKET@1440全市场汇总
        'kline_batch' => 'KlineBatchStrategy',       # ✅ 保留：K线双窗口推送
        # 'trade_batch' => 'TradeBatchStrategy',     # 已禁用，使用 TradeBatchJob 代替（增量广播架构）
        'depth' => 'DepthStrategy',
        'market_realtime' => 'MarketRealtimeStrategy',
        # 'ticker_realtime' => 'TickerRealtimeStrategy'  # ❌ 停用(2025-01)：功能被MARKET@1440覆盖，造成数据冗余和K线重复
      }.freeze

      sidekiq_options queue: :broadcast, retry: 3

      def perform(broadcast_type, params)
        start_time = Time.current

        Rails.logger.info "[MarketData::Broadcast::Worker] Starting #{broadcast_type} broadcast"

        strategy = get_strategy(broadcast_type)
        raise ArgumentError, "Unsupported broadcast type: #{broadcast_type}" unless strategy

        result = strategy.execute(params)

        log_completion(broadcast_type, result, start_time)

        result
      rescue => e
        Rails.logger.error "[MarketData::Broadcast::Worker] Error in #{broadcast_type}: #{e.message}"
        Rails.logger.error e.backtrace.join("\n")
        raise
      end

      private

      def get_strategy(broadcast_type)
        strategy_class_name = BROADCAST_TYPES[broadcast_type]
        return nil unless strategy_class_name

        strategy_class = "Jobs::MarketData::Broadcast::Worker::#{strategy_class_name}".constantize
        strategy_class.new
      rescue NameError
        nil
      end

      def log_completion(broadcast_type, result, start_time)
        duration = (Time.current - start_time) * 1000

        Rails.logger.info "[MarketData::Broadcast::Worker] Completed #{broadcast_type} in #{duration.round(2)}ms"

        if result.is_a?(Hash) && result[:stats]
          Rails.logger.info "[MarketData::Broadcast::Worker] Stats: #{result[:stats]}"
        end
      end

      # 广播策略基类
      class BaseBroadcastStrategy
        def execute(params)
          raise NotImplementedError, "Subclasses must implement execute method"
        end

        protected

        def broadcast_service
          @broadcast_service ||= ::Realtime::MarketBroadcastService
        end

        def has_active_subscriptions?(channel)
          subscription_guard.has_subscribers?(channel)
        end

        def subscription_guard
          ::Realtime::SubscriptionGuard
        end

        def track_stats(type, success_count, failed_count, skipped_count = 0)
          {
            type: type,
            success: success_count,
            failed: failed_count,
            skipped: skipped_count,
            total: success_count + failed_count + skipped_count
          }
        end
      end

      # Ticker批量广播策略（24小时）
      class TickerBatchStrategy < BaseBroadcastStrategy
        def execute(params)
          # 获取所有活跃市场
          market_ids = Trading::Market.active.pluck(:market_id)

          # 批量计算24h ticker
          tickers = MarketData::TickerCalculator.batch_calculate_24h(market_ids)

          topic = 'MARKET@1440'
          ActionCable.server.broadcast(topic, {
            topic: topic,
            data: tickers
          })

          Rails.logger.info "[TickerBatch] 广播 #{tickers.size} 个市场到 #{topic}"

          {
            success: true,
            stats: track_stats('ticker_batch', tickers.size, 0)
          }
        end
      end

      # K线批量广播策略（支持双窗口推送）
      class KlineBatchStrategy < BaseBroadcastStrategy
        def execute(params)
          batch = params['batch'] || params[:batch] || []
          use_dual_window = params['use_dual_window'] || params[:use_dual_window] || true

          success_count = 0
          failed_count = 0

          batch.each do |pair|
            payload = normalize_kline_batch_item(pair)
            topic = payload[:topic]
            aligned_ts = payload[:timestamp]
            market_id = payload[:market_id]
            interval_minutes = payload[:interval_minutes].to_i
            interval_seconds = interval_minutes * 60
            channel = "#{market_id}@KLINE_#{interval_minutes}"

            # 获取K线数据
            begin
              entry_realtime = payload[:is_realtime]
              if use_dual_window && entry_realtime
                dual_data = MarketData::KlineBuilder.build_with_previous(market_id, interval_seconds)

                # 广播双窗口数据
                ActionCable.server.broadcast(channel, {
                  type: 'KLINE_DUAL_WINDOW',
                  market_id: market_id,
                  interval: interval_seconds,
                  current: dual_data[:current],
                  previous: dual_data[:previous]
                })
                success_count += 1
              else
                # 传统单窗口模式（兼容旧逻辑）
                if entry_realtime
                  kline_data = MarketData::KlineBuilder.build_realtime(market_id, interval_seconds)
                else
                  start_time = aligned_ts - interval_seconds
                  kline_data = MarketData::KlineBuilder.build(market_id, interval_seconds, start_time, aligned_ts)
                end

                if broadcast_service.broadcast_kline(market_id, interval_seconds, kline_data)
                  success_count += 1
                else
                  failed_count += 1
                end
              end
            rescue => e
              Rails.logger.error "[KlineBatch] 广播失败 #{channel}: #{e.message}"
              failed_count += 1
            end
          end

          {
            success: true,
            stats: track_stats('kline_batch', success_count, failed_count, 0)
          }
        end

        private

        def normalize_kline_batch_item(item)
          if item.is_a?(Hash)
            return item.symbolize_keys
          elsif item.is_a?(Array)
            topic = item[0]
            timestamp = item[1]
            meta = (item[2] || {}).symbolize_keys
            return {
              topic: topic,
              timestamp: timestamp,
              market_id: meta[:market_id],
              interval_minutes: meta[:interval_minutes],
              is_realtime: meta[:is_realtime]
            }
          end

          {}
        end
      end

      # ==================== Trade批量广播策略 ====================
      #
      # ⚠️ 当前已禁用，使用 TradeBatchJob + 增量广播架构代替
      #
      # 【保留原因】
      # 1. 客户端重连场景：未来可能需要批量推送最近N笔成交帮助客户端快速同步
      # 2. 数据修复场景：历史成交数据需要重新广播时可以使用
      # 3. 架构参考：保留完整的批量广播实现作为参考
      # 4. 降级方案：如果增量广播出现问题，可以快速回退到批量模式
      #
      # 【旧架构 vs 新架构】
      # - 旧架构（本类）：
      #   * 每次OrderFill创建 → 查询最近10笔成交 → 全量广播（包含历史数据）
      #   * 前端接收：完全替换列表
      #   * 问题：重复数据、带宽浪费、数据库查询频繁
      #
      # - 新架构（TradeBatchJob）：
      #   * OrderFill创建 → 添加到Redis队列 → 时间窗口聚合 → 增量广播（只推送新数据）
      #   * 前端接收：增量追加 + 去重
      #   * 优势：无重复、带宽节省90%、数据库查询减少80%
      #
      # 【如何启用】
      # 1. 在 BROADCAST_TYPES 中取消注释：'trade_batch' => 'TradeBatchStrategy'
      # 2. 修改 order_fill.rb 回调使用 Worker
      # 3. 配置调度策略或手动触发
      # 4. 修改前端为批量替换模式（去掉增量追加逻辑）
      # 5. 重新启用 TradeHeartbeatStrategy（30秒心跳）
      #
      # ==================== 代码开始 ====================
      #
      # 成交批量广播策略（旧实现）
      class TradeBatchStrategy < BaseBroadcastStrategy
        def execute(params)
          batch = params['batch'] || params[:batch] || []
          is_heartbeat = params['is_heartbeat'] || params[:is_heartbeat] || false

          success_count = 0
          failed_count = 0

          batch.each do |pair|
            topic, _ = pair
            parsed = ::Realtime::TopicParser.parse_topic(topic)
            next unless parsed

            market_id = parsed[:market_id]
            topic_key = "trade:#{market_id}"

            if is_heartbeat
              # 心跳广播：发送标记为心跳的消息
              heartbeat_data = {
                topic: "#{market_id}@TRADE",
                data: {
                  is_heartbeat: true,
                  ts: Time.current.to_i
                }
              }

              if has_active_subscriptions?("#{market_id}@TRADE")
                ActionCable.server.broadcast("#{market_id}@TRADE", heartbeat_data)
                success_count += 1

                # 记录心跳发送时间（不是数据更新时间）
                ::Realtime::HeartbeatService.record_heartbeat(topic_key)
              else
                failed_count += 1
              end
            else
              # 正常数据广播 - 从数据库获取最新成交数据
              begin
                redis_key = "trade:#{market_id}"

                # 获取最近10笔成交
                fills = Trading::OrderFill.where(market_id: market_id)
                                          .order(block_timestamp: :desc)
                                          .limit(10)

                if fills.any?
                  trades = fills.map do |fill|
                    volume = fill.filled_amount.to_f
                    next if volume.zero?

                    dist = fill.price_distribution&.first
                    total_amount = dist ? dist["total_amount"].to_f : 0.0
                    price = (volume.zero? ? 0.0 : (total_amount / volume))

                    direction = fill.order.order_direction
                    trade_type = if direction == 'Offer'
                                  1
                                elsif direction == 'List'
                                  2
                                else
                                  0
                                end

                    [
                      fill.block_timestamp.to_i,
                      price.to_i,              # 保持Wei格式
                      volume.round(6),
                      trade_type
                    ]
                  end.compact

                  data = {
                    topic: "#{market_id}@TRADE",
                    data: trades
                  }

                  # 缓存数据
                  Sidekiq.redis { |conn| conn.set(redis_key, data.to_json) }

                  # 广播
                  ActionCable.server.broadcast("#{market_id}@TRADE", data)

                  # 记录数据更新时间
                  ::Realtime::HeartbeatService.record_update(topic_key)

                  success_count += 1
                else
                  failed_count += 1
                end
              rescue => e
                Rails.logger.error "[TradeBatchStrategy] Error broadcasting trades for #{market_id}: #{e.message}"
                failed_count += 1
              end
            end
          end

          stats_type = is_heartbeat ? 'trade_heartbeat' : 'trade_batch'

          {
            success: true,
            stats: track_stats(stats_type, success_count, failed_count)
          }
        end
      end

      # 深度广播策略
      class DepthStrategy < BaseBroadcastStrategy
        def execute(params)
          market_id = params['market_id'] || params[:market_id]
          limit = params['limit'] || params[:limit] || 20
          is_heartbeat = params['is_heartbeat'] || params[:is_heartbeat] || false

          # 对于心跳广播，先检查是否真的需要发送
          # （避免在订单刚更新后立即发送心跳）
          if is_heartbeat && recently_updated?(market_id)
            Rails.logger.debug "[DepthBroadcast] Skipping heartbeat for #{market_id}, recently updated"
            return { success: true, stats: track_stats('depth_heartbeat', 0, 0, 1) }
          end

          success = broadcast_service.broadcast_depth(market_id, limit, is_heartbeat)

          {
            success: success,
            stats: track_stats(is_heartbeat ? 'depth_heartbeat' : 'depth', success ? 1 : 0, success ? 0 : 1)
          }
        end

        private

        # 检查深度数据是否最近更新过（5秒内）
        def recently_updated?(market_id)
          last_update_key = "depth_last_update:#{market_id}"
          last_update = Sidekiq.redis { |conn| conn.get(last_update_key) }

          return false if last_update.nil?

          (Time.current.to_i - last_update.to_i) < 5
        end
      end

      # 市场实时广播策略
      class MarketRealtimeStrategy < BaseBroadcastStrategy
        def execute(params)
          topic = params['topic'] || params[:topic] || 'MARKET@realtime'

          success = broadcast_service.broadcast_market_realtime(topic)

          {
            success: success,
            stats: track_stats('market_realtime', success ? 1 : 0, success ? 0 : 1)
          }
        end
      end

      # Ticker实时广播策略（支持多周期）
      class TickerRealtimeStrategy < BaseBroadcastStrategy
        # 支持的广播周期（分钟）
        BROADCAST_INTERVALS = [30, 60, 360, 720, 1440].freeze

        def execute(params)
          # 1. 获取有变化的市场（从独立队列）
          changed_markets = Sidekiq.redis { |conn| conn.smembers("changed_markets:realtime") }
          if changed_markets.empty?
            Rails.logger.debug "[TickerRealtime] 无市场变化，跳过"
            return { success: true, stats: track_stats('ticker_realtime', 0, 0) }
          end

          # 清除自己的标记（不影响batch队列）
          Sidekiq.redis { |conn| conn.del("changed_markets:realtime") }

          success_count = 0
          failed_count = 0

          # 2. 为每个市场的每个周期计算和广播ticker（不再在执行层做订阅检查）
          changed_markets.each do |market_id|
            BROADCAST_INTERVALS.each do |interval_minutes|
              # 使用与前端一致的通道格式
              channel = "#{market_id}@TICKER_#{interval_minutes}"

              begin
                # 计算特定周期的ticker
                ticker = MarketData::TickerCalculator.calculate_with_interval(
                  market_id,
                  interval_minutes
                )

                if ticker
                  # 广播ticker数据
                  ActionCable.server.broadcast(channel, {
                    topic: channel,
                    type: "TICKER",
                    data: ticker
                  })
                  success_count += 1
                  Rails.logger.debug "[TickerRealtime] 广播ticker: #{channel}"
                else
                  Rails.logger.warn "[TickerRealtime] ticker计算返回nil: #{channel}"
                  failed_count += 1
                end
              rescue => e
                Rails.logger.error "[TickerRealtime] 处理失败 #{channel}: #{e.message}"
                failed_count += 1
              end
            end
          end

          Rails.logger.info "[TickerRealtime] 成功广播 #{success_count} 个ticker，失败 #{failed_count} 个"

          {
            success: true,
            stats: track_stats('ticker_realtime', success_count, failed_count)
          }
        end
      end

      # Ticker批量广播策略（24小时汇总）- 优化版
      class TickerBatchStrategyV2 < BaseBroadcastStrategy
        INTERVAL_SECONDS = 86400  # 24小时

        def execute(params)
          # 1. 获取所有活跃市场
          all_markets = Trading::Market.all.pluck(:market_id)

          # 2. 获取有变化的市场（从独立队列）
          changed_markets = Sidekiq.redis { |conn| conn.smembers("changed_markets:batch") }

          Rails.logger.debug "[TickerBatch] 总市场数: #{all_markets.size}, 有变化: #{changed_markets.size}"

          # 3. 计算ticker（优先使用缓存）
          tickers = all_markets.map do |market_id|
            if changed_markets.include?(market_id.to_s)
              # 有变化：重新计算（会查询数据库）
              ticker = MarketData::TickerCalculator.calculate_with_interval(market_id, 1440)
              Rails.logger.debug "[TickerBatch] 重新计算市场#{market_id}: #{ticker ? '成功' : 'nil'}"
              ticker
            else
              # 无变化：从缓存读取
              read_ticker_from_cache(market_id)
            end
          end.compact

          # 4. 为缺失ticker的市场创建占位
          formatted_tickers = fill_missing_markets(all_markets, tickers) || []

          # 5. 广播（不再过滤price<=1）
          ActionCable.server.broadcast("MARKET@1440", {
            topic: "MARKET@1440",
            type: "TICKER_BATCH",
            data: formatted_tickers
          })

          # 6. 清除已处理的变化标记
          Sidekiq.redis { |conn| conn.del("changed_markets:batch") } if changed_markets.any?

          placeholder_count = formatted_tickers.count { |t| t && t[:no_trade] }
          Rails.logger.info "[TickerBatch] 广播 #{formatted_tickers.size} 个市场（含#{placeholder_count}个无交易市场）"

          {
            success: true,
            stats: track_stats('ticker_batch', formatted_tickers.size, 0)
          }
        end

        private

        # 从Redis缓存读取ticker
        def read_ticker_from_cache(market_id)
          redis_key = "ticker:#{market_id}:#{INTERVAL_SECONDS}"
          data = Sidekiq.redis { |conn| conn.hgetall(redis_key) }
          return nil if data.empty?

          # 验证缓存有效性（price > 1）
          close_price = data["close"]&.to_i || 0
          return nil if close_price <= 1

          # 转换为ticker格式
          {
            market_id: market_id.to_s,
            symbol: market_id.to_s,  # 直接使用market_id作为symbol
            intvl: 1440,
            values: [
              data["time"]&.to_i || Time.current.to_i,
              data["open"]&.to_i || 0,
              data["high"]&.to_i || 0,
              data["low"]&.to_i || 0,
              data["close"]&.to_i || 0,
              data["volume"]&.to_f || 0.0,
              data["turnover"]&.to_i || 0
            ],
            change: data["change"] || "0%",
            color: data["color"] || "#FFFFF0"
          }
        rescue => e
          Rails.logger.error "[TickerBatch] 缓存读取失败 市场#{market_id}: #{e.message}"
          nil
        end

        # 为缺失ticker的市场创建占位
        def fill_missing_markets(all_markets, existing_tickers)
          existing_map = existing_tickers.index_by { |t| t[:market_id].to_s }

          all_markets.map do |market_id|
            market_id_str = market_id.to_s

            if existing_map[market_id_str]
              # 已有ticker，直接使用
              existing_map[market_id_str]
            else
              # 缺失ticker，创建占位
              create_placeholder_ticker(market_id_str)
            end
          end
        end

        # 创建占位ticker（无交易市场）
        def create_placeholder_ticker(market_id)
          {
            market_id: market_id,
            symbol: market_id.to_s,  # 直接使用market_id作为symbol
            intvl: 1440,
            values: [
              Time.current.to_i,  # time
              0,                  # open
              0,                  # high
              0,                  # low
              0,                  # close
              0.0,                # volume
              0                   # turnover
            ],
            change: "0%",
            color: "#FFFFF0",
            no_trade: true  # 标记为无交易市场
          }
        rescue => e
          Rails.logger.error "[TickerBatch] 创建占位失败 市场#{market_id}: #{e.message}"
          nil
        end
      end
    end
  end
end
end
