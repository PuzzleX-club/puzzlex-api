module MatchingErrors
  # 基础错误类
  class BaseError < StandardError
    attr_reader :details, :suggestions
    
    def initialize(message, details: {}, suggestions: [])
      @details = details
      @suggestions = suggestions
      super(build_message(message))
    end
    
    def to_log_hash
      {
        error_class: self.class.name,
        message: message,
        details: details,
        suggestions: suggestions,
        backtrace: backtrace&.first(5)
      }
    end
    
    private
    
    def build_message(msg)
      result = "[#{self.class.name.demodulize}] #{msg}"
      result += "\n建议：#{suggestions.join('; ')}" if suggestions.any?
      result
    end
  end
  
  # 数据类型错误
  class DataTypeError < BaseError
    def initialize(field, expected, actual, value = nil)
      super(
        "字段 '#{field}' 类型错误",
        details: {
          field: field,
          expected: expected,
          actual: actual,
          value: value&.to_s&.truncate(50)
        },
        suggestions: build_suggestions(expected, actual)
      )
    end
    
    private
    
    def build_suggestions(expected, actual)
      case [expected, actual]
      when ['Integer', 'String'], ['Float', 'String'], ['Numeric', 'String']
        ["使用 .to_f 或 .to_i 转换为数值类型"]
      when ['String', 'Integer'], ['String', 'Float']
        ["使用 .to_s 转换为字符串"]
      else
        ["检查数据源格式", "确认API返回的数据类型"]
      end
    end
  end
  
  # 数据验证错误
  class ValidationError < BaseError
    def initialize(message, invalid_orders: [])
      super(
        message,
        details: { invalid_orders: invalid_orders },
        suggestions: [
          "检查订单状态是否为 'validated'",
          "确认订单未被取消或过期",
          "验证订单余额充足"
        ]
      )
    end
  end
  
  # 撮合逻辑错误
  class MatchingLogicError < BaseError
    def initialize(message, market_id: nil, bids_count: 0, asks_count: 0)
      super(
        message,
        details: {
          market_id: market_id,
          bids_count: bids_count,
          asks_count: asks_count
        },
        suggestions: [
          "检查买卖双方价格是否匹配",
          "确认订单数量满足最小交易要求",
          "查看市场深度是否有足够流动性"
        ]
      )
    end
  end
end