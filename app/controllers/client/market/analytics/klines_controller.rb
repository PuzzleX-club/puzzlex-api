module Client
  module Market
    module Analytics
      class KlinesController < ::Client::PublicController
        MAX_LIMIT = 50

        def fetch
          market_id = params[:market_id]
          interval = params[:intvl].to_i
          limit = (params[:limit].presence || MAX_LIMIT).to_i
          limit = MAX_LIMIT if limit > MAX_LIMIT

          start_ts = params[:start_ts].to_i
          end_ts = params[:end_ts].to_i

          last_ts = params[:last_ts].to_i

          Rails.logger.info "[KlinesController] 请求参数: market_id=#{market_id}, interval=#{interval}, start_ts=#{start_ts}, end_ts=#{end_ts}, last_ts=#{last_ts}, limit=#{limit}"

          if start_ts > 0 && end_ts > 0
            # 场景1: 传入了 start_ts, end_ts, 按区间查询 + limit
            klines = ::Trading::Kline
                       .where(market_id: market_id, interval: interval)
                       .where("timestamp >= ? AND timestamp <= ?", start_ts, end_ts)
                       .order(timestamp: :desc)  # 改为降序，与场景2保持一致
                       .limit(limit)

          elsif last_ts > 0
            # 场景2: 只给了 last_ts => 查 last_ts 之前的数据
            # 这里"last_ts之前"是 strictly 小于，前端已有数据，返回不包含 last_ts
            klines = ::Trading::Kline
                       .where(market_id: market_id, interval: interval)
                       .where("timestamp < ?", last_ts)  # 之前
                       .order(timestamp: :desc)         # 从最近往后找
                       .limit(limit)

            # 前端会进行倒序，后端不用倒序
            # klines = klines.reverse

          else
            # 如果都没传 => 看您是否返回空 / 或报错
            return render json: { code: 400, msg: "wrong params" }
          end

          used_fallback = false

          if klines.empty?
            Rails.logger.info "[KlinesController] 指定区间无K线数据，尝试回退到最新历史记录"
            fallback = ::Trading::Kline
                         .where(market_id: market_id, interval: interval)
                         .order(timestamp: :desc)
                         .limit(limit)

            if fallback.present?
              klines = fallback
              used_fallback = true
              Rails.logger.info "[KlinesController] 使用回退数据 #{klines.length} 条"
            end
          end

          if klines.empty?
            Rails.logger.info "[KlinesController] 数据库无K线数据，生成0值K线"
            data = generate_zero_klines(start_ts, end_ts, last_ts, interval, limit)
            reached_end = true
          else
            Rails.logger.info "[KlinesController] 查询到#{klines.length}条K线数据"
            data = klines.map do |k|
              {
                ts: k.timestamp,
                open: k.open.to_s,
                high: k.high.to_s,
                low: k.low.to_s,
                close: k.close.to_s,
                vol: k.volume.to_s,
                tor: k.turnover.to_s
              }
            end

            if used_fallback
              earliest = ::Trading::Kline
                .where(market_id: market_id, interval: interval)
                .minimum(:timestamp)
              reached_end = !earliest || klines.last.timestamp <= earliest
            elsif last_ts > 0
              earliest = ::Trading::Kline
                .where(market_id: market_id, interval: interval)
                .minimum(:timestamp)
              reached_end = !earliest || klines.last.timestamp <= earliest
            else
              reached_end = false
            end
          end

          response = {
            code: 0,
            msg: "获取K线数据成功",
            data: data
          }

          # 只在到达边界时添加标记，保持响应简洁
          response[:end] = true if reached_end

          Rails.logger.info "[KlinesController] 返回响应: data_count=#{data.length}, reached_end=#{reached_end}"
          render json: response
        end

        private

        # 生成0值K线数据
        def generate_zero_klines(start_ts, end_ts, last_ts, interval, limit)
          klines = []

          if last_ts > 0
            # 向前查询模式
            current_ts = align_timestamp_down(last_ts - interval, interval)
          elsif end_ts > 0
            # 区间查询模式
            current_ts = align_timestamp_down(end_ts, interval)
          else
            # 默认从当前时间开始
            current_ts = align_timestamp_down(Time.now.to_i, interval)
          end

          limit.times do
            klines << {
              ts: current_ts,
              open: "0",
              high: "0",
              low: "0",
              close: "0",
              vol: "0",
              tor: "0"
            }

            current_ts -= interval
            break if start_ts > 0 && current_ts < start_ts
          end

          klines
        end

        # 时间戳对齐到interval的整数倍
        def align_timestamp_down(timestamp, interval)
          timestamp - (timestamp % interval)
        end

        # 随机生成K线数据，用于测试
        def generate_random_klines(start_ts, intvl, limit)
          klines = []
          current_ts = start_ts - intvl * 60


          limit.times do
            open = rand(1000..5000).to_f.round(2)
            close = rand(1000..5000).to_f.round(2)
            high = [open, close].max + rand(1..1000).to_f.round(2)
            low = [open, close].min - rand(1..1000).to_f.round(2)
            vol = rand(1000..5000).to_f.round(2)
            tor = vol * ((open + close) / 2).round(2)

            klines << {
              ts: current_ts,
              open: open.to_s,
              high: high.to_s,
              low: low.to_s,
              close: close.to_s,
              vol: vol.to_s,
              tor: tor.to_s
            }

            # 更新时间戳
            current_ts -= intvl * 60
          end



          # 默认降序，后端使用降序，前端反转
          klines
        end
      end
    end
  end
end
