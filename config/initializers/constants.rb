# config/initializers/constants.rb
ETH_ADDRESS_PATTERN = /0x[a-fA-F0-9]{40}/i.freeze
ETH_CHAIN_ID_IN_SIWE_PATTERN = /Chain\s*ID:\s*(\d+)/i.freeze
ETH_NONCE_PATTERN = /Nonce:\s*([a-fA-F0-9]{32})/i.freeze