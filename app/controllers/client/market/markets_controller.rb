# frozen_string_literal: true

module Client
  module Market
    class MarketsController < ::Client::ProtectedController
      # GET /api/market/markets
      # 获取市场列表（面向普通用户，Trading Lite 支持）
      def index
        markets = ::Trading::Market.all

        # 过滤条件
        markets = markets.where(payment_type: params[:payment_type]) if params[:payment_type].present?

        # 排序
        markets = markets.order(created_at: :desc)

        # 预加载物品信息
        item_ids = markets.pluck(:item_id)
        items_by_id = CatalogData::Item.where(item_id: item_ids).index_by(&:item_id)

        # 转换为Ticker格式（与WebSocket MARKET@1440一致）
        tickers = markets.map do |market|
          item = items_by_id[market.item_id]

          # 获取最新K线数据（如果有）
          # TODO: K线功能暂未实装，先跳过查询以避免不存在字段导致接口阻塞
          kline = nil

          # 计算时间戳和OHLC数据
          now = Time.now
          timestamp = kline&.ts || now.to_i

          # 构建values数组 [timestamp, open, high, low, close, vol, tor, pre_close]
          if kline
            values = [
              kline.ts,                # timestamp
              kline.open,              # open
              kline.high,              # high
              kline.low,               # low
              kline.close,             # close
              kline.vol || '0',        # volume
              kline.tor || '0',        # turnover
              kline.close              # pre_close (使用当前close作为pre_close)
            ]
          else
            values = [
              now.to_i, '0', '0', '0', '0', '0', '0', '0'
            ]
          end

          # 计算涨跌幅
          close_val = values[4].to_f
          pre_close_val = values[7].to_f
          if pre_close_val > 0
            change = ((close_val - pre_close_val) / pre_close_val * 100).round(2)
          else
            change = 0.0
          end

          # 颜色：涨为红色，跌为绿色
          color = if change > 0
                   '#FF4444'  # 红色
                 elsif change < 0
                   '#44FF44'  # 绿色
                 else
                   '#FFFFF0'  # 白色
                 end

          {
            market_id: market.market_id,
            symbol: item&.name || "Item##{market.item_id}",
            intvl: 1440,
            values: values,
            change: change.to_s,
            color: color
          }
        end

        render_success(tickers)
      end
    end
  end
end
