# app/models/trading/kline.rb
module Trading
  class Kline < ApplicationRecord
    belongs_to :market, class_name: 'Trading::Market', foreign_key: :market_id, primary_key: :market_id

    validates :market_id, :interval, :timestamp, :open, :high, :low, :close, :volume, :turnover, presence: true
    validates :market_id, uniqueness: { scope: [:interval, :timestamp], message: "should be unique per interval and timestamp" }

    # 可根据需要添加更多的验证和方法
  end
end
