# frozen_string_literal: true

module Blockchain
  # Project-supplied token ID parser.
  #
  # Override every public method when TOKEN_ID_PARSER_MODE=custom.
  # The default implementation raises NotImplementedError so that
  # misconfigured deployments fail loudly instead of silently
  # returning wrong data.
  class CustomTokenIdParser
    # @param token_id [String, Integer] decimal or hex token ID
    # @return [String, nil] extracted item ID as a decimal string
    def item_id(token_id)
      raise NotImplementedError,
            "Blockchain::CustomTokenIdParser#item_id not implemented. " \
            "Provide your own parser in app/services/blockchain/custom_token_id_parser.rb"
    end

    # @param token_id [String, Integer]
    # @return [Integer, nil]
    def item_id_int(token_id)
      value = item_id(token_id)
      return nil if value.nil? || value.to_s.strip.empty?

      Integer(value, 10)
    rescue ArgumentError, TypeError
      nil
    end

    # @param token_id [String, Integer]
    # @return [Integer, nil] quality byte value
    def quality(token_id)
      raise NotImplementedError,
            "Blockchain::CustomTokenIdParser#quality not implemented. " \
            "Provide your own parser in app/services/blockchain/custom_token_id_parser.rb"
    end

    # @param token_id [String, Integer]
    # @return [String] quality as hex string, e.g. "0x10"
    def quality_hex(token_id)
      parsed_quality = quality(token_id)
      return '' if parsed_quality.nil?

      "0x#{parsed_quality.to_s(16)}"
    end
  end
end
