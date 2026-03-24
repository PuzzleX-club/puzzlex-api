# frozen_string_literal: true

require "json"

module Jobs
  module MarketData
    module Broadcast
      # 使用 Trading::MarketIntradayStat 广播 MARKET@1440 数据
      class MarketSnapshotJob
        include Sidekiq::Job

        sidekiq_options queue: :scheduler, retry: 2

        CACHE_PREFIX = "market1440:".freeze
        CACHE_TTL = 90.seconds

        def perform
          begin
            unless Sidekiq::Election::Service.leader?
              Rails.logger.debug "[MarketData::Broadcast::MarketSnapshotJob] 非Leader实例，跳过广播"
              return
            end
          rescue => e
            Rails.logger.error "[MarketData::Broadcast::MarketSnapshotJob] 选举服务异常: #{e.message}，跳过本次广播"
            return
          end

          market_ids = Trading::Market.pluck(:market_id)
          stats = Trading::MarketIntradayStat.where(market_id: market_ids).index_by(&:market_id)

          payload = market_ids.map do |market_id|
            data = stats[market_id]
            if data
              formatted = format_stat_ticker(data)
              cache_market_data(market_id, formatted)
              formatted
            else
              placeholder = create_placeholder_ticker(market_id)
              cache_market_data(market_id, placeholder)
              placeholder
            end
          end.compact

          broadcast(payload)
        rescue => e
          Rails.logger.error "[MarketData::Broadcast::MarketSnapshotJob] 广播失败: #{e.message}"
          Sentry.capture_exception(e) if defined?(Sentry)
          raise
        end

        private

        def broadcast(payload)
          ActionCable.server.broadcast(
            "MARKET@1440",
            {
              topic: "MARKET@1440",
              type: "TICKER_BATCH",
              data: payload,
              generated_at: Time.current.to_i
            }
          )

          Rails.logger.info "[MarketData::Broadcast::MarketSnapshotJob] 广播 #{payload.size} 个市场"
        end

        def cache_market_data(market_id, data)
          Sidekiq.redis { |conn| conn.set(cache_key(market_id), JSON.generate(data), ex: CACHE_TTL.to_i) }
        rescue => e
          Rails.logger.warn "[MarketData::Broadcast::MarketSnapshotJob] 缓存写入失败 market=#{market_id}: #{e.message}"
        end

        def cache_key(market_id)
          "#{CACHE_PREFIX}#{market_id}"
        end

        def format_stat_ticker(stat)
          {
            market_id: stat.market_id.to_s,
            symbol: stat.market_id.to_s,
            intvl: 1440,
            values: [
              stat.window_end_ts,
              stat.open_price_wei.to_s,
              stat.high_price_wei.to_s,
              stat.low_price_wei.to_s,
              stat.close_price_wei.to_s,
              stat.volume.to_f,
              stat.turnover_wei.to_s,
              stat.open_price_wei.to_s
            ],
            change: calculate_change(stat.close_price_wei, stat.open_price_wei),
            color: ticker_color(stat.close_price_wei, stat.open_price_wei),
            has_trade: stat.has_trade,
            fill_count: stat.fill_count,
            no_trade: !stat.has_trade
          }
        end

        def create_placeholder_ticker(market_id)
          {
            market_id: market_id.to_s,
            symbol: market_id.to_s,
            intvl: 1440,
            values: [
              Time.current.to_i,
              "0",
              "0",
              "0",
              "0",
              0.0,
              "0",
              "0"
            ],
            change: "0",
            color: "#FFFFF0",
            has_trade: false,
            fill_count: 0,
            no_trade: true
          }
        end

        def calculate_change(close_price, open_price)
          open = BigDecimal(open_price.to_s)
          return "0" if open.zero?

          change = ((BigDecimal(close_price.to_s) - open) / open * 100).round(2)
          change.to_s
        end

        def ticker_color(close_price, open_price)
          close_val = BigDecimal(close_price.to_s)
          open_val = BigDecimal(open_price.to_s)

          if close_val > open_val
            "#0ECB81"
          elsif close_val < open_val
            "#F6465D"
          else
            "#FFFFF0"
          end
        end
      end
    end
  end
end
