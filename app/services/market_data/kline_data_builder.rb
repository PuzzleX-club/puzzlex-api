# app/services/market_data/kline_data_builder.rb
module MarketData
  class KlineDataBuilder
    # 参数举例：
    # market_id: 市场ID
    # interval: 以秒为单位的间隔。例如60表示1分钟
    # end_time: 当前周期的结束时间戳 (例如当前时间)
    # steps: 当前周期需要分几次发送数据（等同于 broadcast任务中steps含义）
    # 注意：以下逻辑只是示例，需根据实际数据库结构和数据字段进行调整
    def initialize(market_id:, interval:, end_time:, steps:)
      @market = MarketData::MarketIdParser.new(market_id:market_id)  # 通过market_id解析出market对象
      # interval以秒为单位
      @interval = interval || 60
      @end_time = end_time || 60
      @steps = steps || 1
      @start_time = @end_time - @interval
      @market_id = market_id
    end

    # 构建本周期的K线数据
    def build_cycle_data
      result = []
      @steps.times do |i|
        # 计算该区间的start, end
        seg_end = @end_time - i * @interval
        seg_start = seg_end - @interval
        # 从fills表中读取 [@start_time, @end_time] 区间内的成交数据
        # 假设fill中有: timestamp(秒), price, volume
        # 删选时间范围的时候左开右闭，保证kline的数据不会重复
        # .where("EXISTS (
        #                            SELECT 1
        #                            FROM jsonb_array_elements(price_distribution) AS elem
        #                            WHERE elem->>'token_address' = ?
        #                          )", @market.price_address.downcase)
        fills = Trading::OrderFill
                  .where(market_id: @market_id)
                  .where("block_timestamp > ? AND block_timestamp <= ?", seg_start, seg_end)
                  .select(:filled_amount, :price_distribution, :block_timestamp)
                  .order(:block_timestamp) # 确保按照时间顺序排序
                  .to_a

        return default_kline_data(seg_end) if fills.empty?

        # 存储所有单独的成交记录
        all_fills = []

        fills.each do |fill|
          # 检查price_distribution是否为数组且只有一个元素，多个对价的情况无法实现K线图
          next unless fill.price_distribution.is_a?(Array) && fill.price_distribution.size == 1

          distribution = fill.price_distribution.first

          # 获取total_amount并计算price
          total_amount = distribution["total_amount"].to_f
          volume = fill.filled_amount.to_f

          # 避免除以零
          next if volume.zero?

          price = total_amount / volume

          # 需要根据实际结构进行调整
          # 添加到all_fills
          all_fills << { price: price, volume: volume, timestamp: fill.block_timestamp }
        end

        return default_kline_data(seg_end) if all_fills.empty?


        # 按时间顺序排列所有成交记录
        all_fills.sort_by! { |f| f[:timestamp] }

        # 计算open, high, low, close, volume, turnover
        # 注意：price已经是Wei格式（从OrderFill.price_distribution.total_amount计算得到）
        open_price = all_fills.first[:price]
        close_price = all_fills.last[:price]
        high_price = all_fills.map { |f| f[:price] }.max
        low_price = all_fills.map { |f| f[:price] }.min
        total_volume = all_fills.map { |f| f[:volume] }.sum
        turnover = all_fills.map { |f| f[:price] * f[:volume] }.sum

        # 日志记录K线数据
        # Rails.logger.info "Kline Data - Open: #{open_price}, High: #{high_price}, Low: #{low_price}, Close: #{close_price}, Volume: #{total_volume}, Turnover: #{turnover}"

        # 价格字段保持Wei格式（整数），避免科学计数法导致的转换错误
        # turnover也是Wei格式（price * volume）
        kline_for_this_step =[
          seg_end,
          open_price.round(0).to_i.to_s,    # Wei整数字符串
          high_price.round(0).to_i.to_s,
          low_price.round(0).to_i.to_s,
          close_price.round(0).to_i.to_s,
          total_volume.round(2).to_s,       # 数量保留2位小数
          turnover.round(0).to_i.to_s       # Wei整数字符串
        ]
        result << kline_for_this_step
      end
      result.sort_by! { |kline| kline[0] }  # 按start_time升序
      result
    end

    # 生成默认数据
    # 在presister中将完成将空白数据填充为prev数据的功能
    def default_kline_data(end_time)
      price = 0.00
      # 注意，应该参照实际的K线数据结构进行调整
      [[
        end_time,
        price.to_s, # open
        price.to_s, # high
        price.to_s, # low
        price.to_s, # close
        "0.00",     # volume
        "0.00"      # turnover
      ]]
    end
  end
end
