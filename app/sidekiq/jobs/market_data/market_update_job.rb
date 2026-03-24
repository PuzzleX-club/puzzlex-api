# app/sidekiq/jobs/market_data/market_update_job.rb
require 'bigdecimal'

module Jobs
  module MarketData
    class MarketUpdateJob
      include Sidekiq::Job
    
      sidekiq_options queue: :default, retry: false
    
      def perform(params)
        # 在任务开始时设置退出时的钩子
        at_exit { clean_up_redis }
        # 1. 从参数中取对齐时间（仅示例，实际可根据你的业务逻辑取值）
        # Rails.logger.debug("MarketUpdateJob params: #{params}")
        # 注意sidekiq传递的参数是字符串，不是ruby symbol。解析需要注意
        list_of_pairs = params["list_of_pairs"]
        # 是否是初始化
        is_init = params["is_init"] || false
    
        # 2. 一次性获取 market_id、base_currency，组装成数组/哈希
        #    SELECT market_id, base_currency FROM puzzlex.markets
        markets_info = Trading::Market
                         .select(:market_id, :base_currency)
                         .map { |m| { market_id: m.market_id, base_currency: m.base_currency } }
    
        # 释放连接，减轻连接池压力
        ActiveRecord::Base.connection_pool.release_connection
    
        # 3. 遍历 list_of_pairs，处理每个 topic 和 aligned_ts
        list_of_pairs.each do |pair|
          topic = pair[0]            # 访问 topic
          next_align_ts = pair[1]    # 访问 aligned_ts
    
          Rails.logger.debug("Processing topic: #{topic} with align timestamp: #{next_align_ts}")
    
          # 使用 realtime topic parser 解析 topic
          parsed = ::Realtime::TopicParser.parse_topic(topic)
    
          # 4. 每次处理5个市场后释放连接
          markets_info.each_slice(5) do |markets_batch|
            markets_batch.each do |m_info|
              Rails.logger.debug("Starting initiating Redis for market: #{m_info[:market_id]} with timestamp: #{next_align_ts}")
    
              if is_init
                # 如果是初始化 => 填充初始信息
                Rails.logger.debug("Initializing Redis for market: #{m_info[:market_id]}")
                preclose_price = compute_preclose(m_info[:market_id], next_align_ts - parsed[:interval] * 60) # 回溯前一个区间
                initialize_market_in_redis(m_info, preclose_price, parsed, next_align_ts)
              else
                # 如果不是初始化 => 正常更新
                preclose_price = compute_preclose(m_info[:market_id], next_align_ts)
                reset_market_in_redis(m_info, preclose_price, parsed, next_align_ts)
              end
            end
            
            # 每处理一批（5个市场）后释放数据库连接
            ActiveRecord::Base.connection_pool.release_connection
          end
        end
      end
    
      private
    
      # 格式化Wei价格，确保为整数字符串，避免科学记数法
      def format_wei_price(price)
        return "0" if price.nil?
    
        numeric = case price
                  when BigDecimal then price.to_i
                  when Integer then price
                  when Float then price.to_i
                  else
                    BigDecimal(price.to_s).to_i
                  end
    
        numeric.to_s
      end
    
      # 在此方法中使用 "next_align_ts" 来获取"在这个时间点之前"的最新一笔 Fill
      def compute_preclose(market_id, align_ts)
        # 使用统一的前收盘价计算服务
        ::MarketData::PrecloseCalculator.calculate(market_id, align_ts)
      end
    
      # 初始化时写入 Redis
      def initialize_market_in_redis(m_info, preclose_price, parsed, next_align_ts)
        interval = parsed[:interval]
        now = Time.now.utc.to_i
        start_ts = next_align_ts - (interval * 60)
    
        # 使用统一的K线构建服务
        kline_for_this_step = ::MarketData::KlineBuilder.build(
          m_info[:market_id],
          interval,
          start_ts,
          now
        )
    
        # 如果没有数据，使用预关闭价格
        if BigDecimal(kline_for_this_step[1].to_s).zero? && BigDecimal(kline_for_this_step[4].to_s).zero?
          kline_for_this_step = [
            now,
            format_wei_price(preclose_price),
            format_wei_price(preclose_price),
            format_wei_price(preclose_price),
            format_wei_price(preclose_price),
            '0',
            format_wei_price(0)
          ]
        end
    
        close_val     = BigDecimal(kline_for_this_step[4].to_s)
        pre_close_val = BigDecimal(preclose_price.to_s)
    
        # 避免除零
        ratio = if pre_close_val.zero?
                  0
                else
                  (close_val - pre_close_val) / pre_close_val
                end
    
        change_percentage = (ratio * 100).round(2)  # 例如 3.56%
        color = "#FFFFF0"  # 默认
    
        if close_val > pre_close_val
          color = "#0ECB81"
        elsif close_val < pre_close_val
          color = "#F6465D"
        end
    
        Rails.logger.debug("Initiating Redis for market: #{m_info[:market_id]} with interval: #{parsed[:interval]}")
    
        # 使用统一的Redis数据服务
        market_data = {
          "market_id" => m_info[:market_id],
          "symbol" => m_info[:market_id],
          "intvl" => parsed[:interval] || 0,
          "time" => kline_for_this_step[0].to_s,
          "open" => format_wei_price(kline_for_this_step[1]),
          "high" => format_wei_price(kline_for_this_step[2]),
          "low" => format_wei_price(kline_for_this_step[3]),
          "close" => format_wei_price(kline_for_this_step[4]),
          "vol" => kline_for_this_step[5].to_s,
          "tor" => format_wei_price(kline_for_this_step[6]),
          "change" => "#{change_percentage}%",
          "color" => color,
          "pre_close" => format_wei_price(pre_close_val),
          "close_val" => format_wei_price(close_val),
          "pre_close_val" => format_wei_price(pre_close_val)
        }
    
        ::RuntimeCache::MarketDataStore.update_market_summary(m_info[:market_id], market_data)
    
        # 还可以加其他字段，具体看你初始化需要哪些默认值
      end
    
      # 重置/更新 Redis:
      # 假设你在 Redis 用 hash 存放某个 market 的信息
      # key: "market:#{market_id}"
      # field: "preclose"
      def reset_market_in_redis(m_info, preclose_price, parsed, next_align_ts)
        # 使用统一的Redis数据服务
        market_data = {
          "market_id" => m_info[:market_id],
          "symbol" => m_info[:market_id],
          "intvl" => parsed[:interval],
          "time" => next_align_ts.to_s,
          "open" => format_wei_price(preclose_price),
          "high" => format_wei_price(preclose_price),
          "low" => format_wei_price(preclose_price),
          "close" => format_wei_price(preclose_price),
          "vol" => "0",
          "tor" => "0",
          "change" => "0%",
          "color" => "#FFFFF0",
          "pre_close" => format_wei_price(preclose_price),
          "close_val" => format_wei_price(preclose_price),
          "pre_close_val" => format_wei_price(preclose_price)
        }
    
        ::RuntimeCache::MarketDataStore.update_market_summary(m_info[:market_id], market_data)
      end
    
    
      def clean_up_redis
        # 在这里加入你需要删除的 Redis 键或清理逻辑
        Rails.logger.info "Cleaning up Redis for market..."
        
        # 使用统一的Redis键管理器
        ::RuntimeCache::Keyspace.delete_keys_by_pattern("market:*")
      end
    end
  end
end
