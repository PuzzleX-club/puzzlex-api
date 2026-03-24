# frozen_string_literal: true

module MarketData
  module TimeAlignment
    def align_to_interval(time, interval_in_minutes)
      if interval_in_minutes == 0
        Rails.logger.error "❌ [MarketData::TimeAlignment] interval_in_minutes is 0"
        Rails.logger.error "❌ [MarketData::TimeAlignment] Call stack: #{caller.join("\n")}"
        raise ArgumentError, "interval_in_minutes cannot be 0"
      end

      now_s = time.to_i
      interval_s = interval_in_minutes * 60
      remainder = now_s % interval_s

      if remainder == 0
        Rails.logger.debug "[MarketData::TimeAlignment] already aligned: #{now_s}"
        now_s
      else
        aligned_time = now_s - remainder + interval_s
        Rails.logger.debug "[MarketData::TimeAlignment] next aligned time: #{aligned_time}"
        aligned_time
      end
    end
  end
end
