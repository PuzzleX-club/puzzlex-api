# frozen_string_literal: true

module Indexer
  # TokenId解析器
  # 完全复刻The Graph索引器的tokenId解析逻辑
  class TokenParser
    def initialize(parser: ::Blockchain::TokenIdParser.new)
      @parser = parser
    end

    # 从tokenId提取itemId
    # @param token_id [String] tokenId的十进制字符串
    # @return [String] itemId
    def get_item_id(token_id)
      @parser.item_id(token_id).to_s
    end

    # 从tokenId提取quality
    # @param token_id [String] tokenId的十进制字符串
    # @return [String] quality的hex表示 (如 "0x10")
    def get_quality(token_id)
      @parser.quality_hex(token_id)
    end

    private

    attr_reader :parser

    def embedded_mode?
      parser.embedded_mode?
    end
  end
end
