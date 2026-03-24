# app/services/market_data/market_id_parser.rb
module MarketData
  class MarketIdParser
    # 常量Rails.application.config.x.blockchain.price_token_type_map 用于将最后两位解析出的代币类型字符串映射到相应信息，如symbol和address
    # 例如：Rails.application.config.x.blockchain.price_token_type_map["00"] => { symbol: "ETH",  address: "0x0000000000000000000000000000000000000000" }

    # def self.call(market_id)
    #   new(market_id)
    # end

    # 假设 Rails.application.config.x.blockchain.price_token_type_map 如:
    #   {
    #     "00" => { symbol: "ETH", address: "0x0000000000000000000000000000000000000000" },
    #     "01" => { symbol: "USDC", address: "0xA0b86991c6218b36c1d19d4a2e9eb0ce3606eb48" }
    #   }

    # 允许同时传入:
    #  1) market_id: "12300"
    #  2) item_id + price_address: (123, "0xA0b8...")
    # 只要满足其中一组即可. 优先使用 market_id, 否则 fallback 到 item_id+price_address
    def initialize(market_id: nil, item_id: nil, price_address: nil)
      @market_id_str      = market_id&.to_s
      @item_id_param      = item_id
      @price_address_param= price_address

      if @market_id_str.present?
        parse_market_id
      elsif @item_id_param.present? && @price_address_param.present?
        parse_by_item_and_address
      else
        # 如果两种都没传, 就置空
        @item_id = nil
        @price_token_type_key = nil
      end
    end

    # 返回解析出的 item_id（整形或nil）
    def item
      @item_id
    end

    # 返回解析得到或生成的 market_id (string)
    def market_id
      # 如果是通过 parse_market_id => @market_id_str就存在
      return @market_id_str if @market_id_str.present?

      # 否则如果 parse_by_item_and_address => @item_id + @price_token_type_key
      return nil unless @item_id && @price_token_type_key
      # 拼接: "#{item_id}#{price_token_type_key}"
      "#{@item_id}#{@price_token_type_key}"
    end

    # 返回价格代币的symbol
    def price_symbol
      token_info = Rails.application.config.x.blockchain.price_token_type_map[@price_token_type_key]
      token_info ? token_info[:symbol] : nil
    end

    # 返回价格代币的address
    def price_address
      token_info = Rails.application.config.x.blockchain.price_token_type_map[@price_token_type_key]
      token_info ? token_info[:address] : nil
    end

    private

    def parse_market_id
      # 确保market_id至少2位
      if @market_id_str.length < 2
        @item_id = nil
        @price_token_type_key = nil
        return
      end

      @price_token_type_key = @market_id_str[-2..-1]  # 最后两位代表price token类型
      item_id_str = @market_id_str[0..-3]             # 除最后两位外的前部分为item_id

      @item_id = item_id_str.empty? ? nil : item_id_str.to_i
    end

    def parse_by_item_and_address
      @item_id = @item_id_param
      # 在 Rails.application.config.x.blockchain.price_token_type_map 中找“哪一个 key 对应的 address 与传入 price_address_param匹配”
      found_key = Rails.application.config.x.blockchain.price_token_type_map.keys.find do |k|
        # 可能要大小写无关对比 => .casecmp? ...
        Rails.application.config.x.blockchain.price_token_type_map[k][:address].casecmp?(@price_address_param)
      end
      @price_token_type_key = found_key  # 可能找不到 => nil
    end
  end
end
