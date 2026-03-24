# frozen_string_literal: true

Rails.application.config.x.token_id_parser = ActiveSupport::OrderedOptions.new

cfg = Rails.application.config.x.token_id_parser

cfg.mode = ENV.fetch('TOKEN_ID_PARSER_MODE', 'embedded').to_s
cfg.embedded_prefix = ENV.fetch('TOKEN_ID_PARSER_EMBEDDED_PREFIX', '0x10').to_s
cfg.erc20_prefix = ENV.fetch('TOKEN_ID_PARSER_ERC20_PREFIX', '0x20').to_s
cfg.hash_bytes = ENV.fetch('TOKEN_ID_PARSER_HASH_BYTES', '16').to_i
cfg.quality_bytes = ENV.fetch('TOKEN_ID_PARSER_QUALITY_BYTES', '1').to_i

if defined?(Rails.logger) && Rails.logger
  Rails.logger.info "[TokenIdParser] Mode: #{cfg.mode}"
  if cfg.mode == 'custom'
    Rails.logger.info "[TokenIdParser] Custom parser: Blockchain::CustomTokenIdParser"
  else
    Rails.logger.info "[TokenIdParser] Embedded prefix: #{cfg.embedded_prefix}"
    Rails.logger.info "[TokenIdParser] ERC20 prefix: #{cfg.erc20_prefix}"
    Rails.logger.info "[TokenIdParser] Hash bytes: #{cfg.hash_bytes}"
    Rails.logger.info "[TokenIdParser] Quality bytes: #{cfg.quality_bytes}"
  end
end
