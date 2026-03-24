# app/services/market_data/kline_persister.rb
module MarketData
  class KlinePersister
    # 用于管理K线补充持久化逻辑
    # 关键目标：
    #   1) 找到kline表最新一条 (market_id, interval) => last_timestamp
    #   2) 若无记录 => 从 fills 中查最早成交 => start_timestamp
    #   3) 按 interval 对齐时间，对每个区间构建K线并保存

    def initialize(market_id:, interval:)
      @market_id = market_id
      @interval  = interval    # 改用秒作为单位，避免精度问题
    end

    # 主入口
    # end_time: 默认为当前时间戳(秒)
    # 返回：本次新增k线个数
    def complete_kline_data(end_time: Time.now.to_i)
      step_seconds = @interval

      # 1) 查kline表中 (market_id, interval) 已存在的最高timestamp
      last_kline_ts = Trading::Kline
                        .where(market_id: @market_id, interval: @interval)
                        .maximum(:timestamp)  # => nil若无记录

      if last_kline_ts
        # 从 (last_kline_ts + step_seconds) 开始写
        # todo:需要确认K线数据的时间戳是起始时间，其实时间的话，遇到start_ts大于当前时间的情况，需要处理。更新，已调整为
        # K线中的时间戳是结束时间，采用时间向step中前追溯，所以不会出现这种情况
        start_ts = last_kline_ts + step_seconds
      else
        # 无任何k线 => 去fills中找最早block_timestamp
        earliest_fill = Trading::OrderFill
                          .where(market_id: @market_id)   # 关键：只筛选本市场
                          .order(:block_timestamp)
                          .limit(1)
                          .first
        return 0 unless earliest_fill  # 若无fill，无法补 => 直接返回
        # 对齐 earliest_fill.block_timestamp
        # K线的timestamp是区间结束时间，所以需要加上step_seconds
        start_ts = align_timestamp_down(earliest_fill.block_timestamp) + step_seconds
      end

      # end_time 同样对齐
      end_ts = align_timestamp_down(end_time)

      inserted_count = 0
      ts = start_ts
      while ts <= end_ts
        # 构建 [ts, ts+step_seconds) 这个区间的k线
        record = Trading::Kline.find_or_initialize_by(
          market_id: @market_id,
          interval:  @interval,
          timestamp: ts
        )
        # 调用 MarketData::KlineDataBuilder
        kline_data = MarketData::KlineDataBuilder.new(market_id: @market_id,interval: @interval, end_time: ts,steps: 1).build_cycle_data[0]
        if kline_data[5].to_f > 0
          # 数据库字段已改为bigint，存储Wei值
          # KlineDataBuilder已返回Wei整数字符串，直接转换即可
          # 注意：不要用.to_i，因为科学计数法字符串会转换错误，应该用.to_f.to_i
          record.open     = kline_data[1].to_f.round(0).to_i
          record.high     = kline_data[2].to_f.round(0).to_i
          record.low      = kline_data[3].to_f.round(0).to_i
          record.close    = kline_data[4].to_f.round(0).to_i
          record.volume   = kline_data[5].to_f
          record.turnover = kline_data[6].to_f.round(0).to_i
          record.save!
          inserted_count += 1 if record.previously_new_record?
        else
          # 无成交 => 使用上一条K线的 close 作为当前K线的 open/high/low/close
          prev_kline = Trading::Kline
                         .where(market_id: @market_id, interval: @interval)
                         .where("timestamp < ?", ts)
                         .order(timestamp: :desc)
                         .first

          if prev_kline
            # 用上一条K线的收盘价
            prev_close = prev_kline.close
            record.open  = prev_close
            record.high  = prev_close
            record.low   = prev_close
            record.close = prev_close
          else
            # 如果连上一条K线都没有，就默认都置0
            record.open  ||= 0
            record.high  ||= 0
            record.low   ||= 0
            record.close ||= 0
          end

          record.volume   = 0
          record.turnover = 0
          record.save!
          inserted_count += 1 if record.previously_new_record?
        end

        ts += step_seconds
      end

      inserted_count
    end

    # persist_kline_array主要用来测试和kline的持久化配合，实际应用中不会直接调用
    # kline_array 应当是一个二维数组，每个元素(子数组)形如:
    #   [ start_time, open, high, low, close, volume, turnover ]
    #
    # 例如:
    #   [
    #     [1000, "100.0", "120.0", "90.0", "110.0", "10.0", "1000.0"],
    #     [1060, "110.0", "130.0", "100.0", "120.0", "20.0", "2400.0"]
    #   ]
    #
    # 其中 start_time/timestamp 用于定位区间点, open~turnover 则为字符串或浮点数(可做 to_f).
    #
    # 传入:
    #   market_id:  对应 Trading::Kline 的 :market_id
    #   interval:   对应 Trading::Kline 的 :interval (如 "1m", "5m" 等)
    #   kline_array: 待持久化的K线列表
    #
    # 实现:
    #   对 (market_id, interval, timestamp) find_or_initialize_by
    #   更新 open, high, low, close, volume, turnover 并 save!
    def persist_kline_array(market_id, interval, kline_array)
      kline_array.each do |row|
        # row => [ timestamp, open, high, low, close, volume, turnover ]
        ts         = row[0]
        open_price = row[1].to_f
        high_price = row[2].to_f
        low_price  = row[3].to_f
        close_price= row[4].to_f
        vol        = row[5].to_f
        turnover   = row[6].to_f

        record = Trading::Kline.find_or_initialize_by(
          market_id: market_id,
          interval:  interval,
          timestamp: ts
        )
        record.open     = open_price
        record.high     = high_price
        record.low      = low_price
        record.close    = close_price
        record.volume   = vol
        record.turnover = turnover
        record.save!
      end
    end

    private

    # 把timestamp对齐到interval的整倍数(秒)
    # @interval 表示多少"秒"
    def align_timestamp_down(timestamp)
      step = @interval
      timestamp - (timestamp % step)
    end

    # 计算此区间 [range_start, range_end] 的OHLCV
    def build_kline_for_range(range_start, range_end)
      fills = Trading::OrderFill
                .where("block_timestamp >= ? AND block_timestamp <= ?", range_start, range_end)
                .order(:block_timestamp)
                .to_a

      return {open:0, high:0, low:0, close:0, volume:0, turnover:0} if fills.empty?

      open_price   = nil
      close_price  = nil
      high_price   = 0
      low_price    = Float::INFINITY
      total_vol    = 0
      total_turnover = 0

      fills.each_with_index do |f, idx|
        price = calc_fill_price(f)
        open_price ||= price
        close_price = price
        high_price  = price if price>high_price
        low_price   = price if price<low_price

        vol = f.filled_amount.to_f
        total_vol += vol
        total_turnover += (price * vol)
      end

      low_price = 0 if low_price == Float::INFINITY

      {
        open: open_price || 0,
        high: high_price,
        low:  low_price,
        close: close_price || 0,
        volume: total_vol,
        turnover: total_turnover
      }
    end

    # 如果 fill.price_distribution里仅有1项 => price= total_amount / fill.filled_amount
    # 可根据您项目灵活实现
    def calc_fill_price(fill)
      dist = fill.price_distribution
      return 0 if dist.blank? || !dist.is_a?(Array) || dist.size!=1
      total_amt = dist.first["total_amount"].to_f
      fill_amt  = fill.filled_amount.to_f
      fill_amt>0 ? (total_amt/fill_amt) : 0
    end

  end
end
