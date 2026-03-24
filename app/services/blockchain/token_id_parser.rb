# frozen_string_literal: true

module Blockchain
  class TokenIdParser
    DEFAULT_MODE = 'embedded'
    SUPPORTED_MODES = %w[embedded identity custom].freeze
    DEFAULT_EMBEDDED_PREFIX = 0x10
    DEFAULT_ERC20_PREFIX = 0x20
    DEFAULT_HASH_BYTES = 16
    DEFAULT_QUALITY_BYTES = 1

    def initialize(config: Rails.application.config.x.token_id_parser)
      @config = config
    end

    def item_id(token_id)
      return nil if token_id.blank?

      case mode
      when 'identity'
        normalize_decimal_string(token_id)
      when 'custom'
        custom_parser.item_id(token_id)
      else
        parse_embedded_item_id(token_id)
      end
    rescue ArgumentError, TypeError => e
      Rails.logger.info "[TokenIdParser] ⚠️ tokenId 解析失败，返回空值: #{e.message}"
      nil
    end

    def item_id_int(token_id)
      return custom_parser.item_id_int(token_id) if mode == 'custom'

      value = item_id(token_id)
      return nil if value.blank?

      Integer(value, 10)
    rescue ArgumentError, TypeError
      nil
    end

    def quality(token_id)
      return nil if token_id.blank?
      return 0 if mode == 'identity'
      return custom_parser.quality(token_id) if mode == 'custom'

      bytes = token_id_to_bytes(token_id)
      return nil if bytes.empty? || bytes[0] != embedded_prefix

      bytes[-quality_bytes]
    rescue ArgumentError, TypeError => e
      Rails.logger.info "[TokenIdParser] ⚠️ token quality 解析失败，返回空值: #{e.message}"
      nil
    end

    def quality_hex(token_id)
      return nil if token_id.blank?
      return custom_parser.quality_hex(token_id) if mode == 'custom'

      parsed_quality = quality(token_id)
      return '' if parsed_quality.nil?

      "0x#{parsed_quality.to_s(16)}"
    end

    def embedded_mode?
      mode == 'embedded'
    end

    private

    attr_reader :config

    def custom_parser
      @custom_parser ||= ::Blockchain::CustomTokenIdParser.new
    end

    def mode
      raw_mode = config&.mode.to_s.strip.downcase
      return DEFAULT_MODE if raw_mode.blank?

      SUPPORTED_MODES.include?(raw_mode) ? raw_mode : DEFAULT_MODE
    end

    def embedded_prefix
      parse_prefix(config&.embedded_prefix, DEFAULT_EMBEDDED_PREFIX)
    end

    def erc20_prefix
      parse_prefix(config&.erc20_prefix, DEFAULT_ERC20_PREFIX)
    end

    def hash_bytes
      value = config&.hash_bytes.to_i
      value.positive? ? value : DEFAULT_HASH_BYTES
    end

    def quality_bytes
      value = config&.quality_bytes.to_i
      value.positive? ? value : DEFAULT_QUALITY_BYTES
    end

    def parse_embedded_item_id(token_id)
      bytes = token_id_to_bytes(token_id)
      return nil if bytes.empty?

      case bytes[0]
      when embedded_prefix
        bytes_to_uint256(extract_embedded_item_bytes(bytes)).to_s
      when erc20_prefix
        bytes_to_uint256(bytes[1..]).to_s
      end
    end

    def extract_embedded_item_bytes(bytes)
      long_format_threshold = 1 + hash_bytes + quality_bytes + 1

      if bytes.length < long_format_threshold
        bytes[1...-quality_bytes]
      else
        bytes[(1 + hash_bytes)...-quality_bytes]
      end
    end

    def token_id_to_bytes(token_id)
      hex = normalize_token_id_hex(token_id)
      return [] if hex.blank?

      [hex].pack('H*').bytes
    end

    def normalize_token_id_hex(token_id)
      raw = token_id.to_s.strip
      return '' if raw.empty?

      hex =
        if raw.start_with?('0x', '0X')
          raw[2..]
        else
          Integer(raw, 10).to_s(16)
        end

      hex = "0#{hex}" if hex.length.odd?
      hex.downcase
    end

    def normalize_decimal_string(token_id)
      raw = token_id.to_s.strip
      return nil if raw.empty?

      raw.start_with?('0x', '0X') ? Integer(raw, 16).to_s : Integer(raw, 10).to_s
    end

    def parse_prefix(raw_value, fallback)
      return fallback if raw_value.blank?

      Integer(raw_value.to_s, 0)
    rescue ArgumentError, TypeError
      fallback
    end

    def bytes_to_uint256(bytes)
      return 0 if bytes.blank?

      bytes.reduce(0) { |result, byte| (result << 8) + byte }
    end
  end
end
