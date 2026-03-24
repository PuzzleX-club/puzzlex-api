# frozen_string_literal: true

module Realtime
  module TopicParser
    # 输入形如:
    #   "MARKET@5"
    #   "BTCUSDT@TICKER_1440"
    #   "BTCUSDT@TRADE"
    #   "BTCUSDT@DEPTH_10"
    #
    # 返回例如:
    #   { market_id: nil,        topic_type: "MARKET",  interval: 5 }
    #   { market_id: "BTCUSDT",  topic_type: "TICKER",  interval: 1440 }
    #   { market_id: "BTCUSDT",  topic_type: "TRADE",   interval: 0 }
    #   { market_id: "BTCUSDT",  topic_type: "DEPTH",   interval: 10 }
    #   DEPTH时，interval为深度档位数
    # 如果格式不符合预期, 返回 nil
    def self.parse_topic(full_topic)
      market_part, type_interval_part = full_topic.to_s.split("@", 2)
      return nil unless market_part && type_interval_part
      return nil if type_interval_part.empty?

      if market_part == "MARKET"
        return {
          market_id: nil,
          topic_type: "MARKET",
          interval: type_interval_part.to_i
        }
      end

      topic_type, interval_str = type_interval_part.split("_", 2)
      interval = interval_str.nil? ? 0 : interval_str.to_i

      {
        market_id: market_part,
        topic_type: topic_type,
        interval: interval
      }
    end
  end
end
