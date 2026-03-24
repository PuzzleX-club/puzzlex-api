# frozen_string_literal: true

module Metadata
  module InstanceMetadata
    # Registry for instance metadata providers.
    #
    # Reads `config.x.instance_metadata.provider` to select the active provider.
    # Supported keys: :api, :example, :none
    #
    class ProviderRegistry
      class << self
        # Returns the currently configured provider instance.
        # Memoized per-process; call `reset!` in tests.
        def current
          @current ||= build_provider
        end

        # Force re-read of config (useful in tests).
        def reset!
          @current = nil
        end

        private

        def build_provider
          key = Rails.application.config.x.instance_metadata.provider

          case key
          when :api
            Providers::ApiProvider.new
          when :example
            Providers::ExampleProvider.new if defined?(Providers::ExampleProvider)
          when :none
            NullProvider.new
          else
            Rails.logger&.warn "[InstanceMetadata] Unknown provider '#{key}', falling back to :none"
            NullProvider.new
          end || NullProvider.new
        end
      end

      # Null provider — always disabled, returns empty results.
      class NullProvider < BaseProvider
        def provider_key
          'none'
        end

        def fetch(_token_id, **_opts)
          { success: false, metadata: nil, error: 'instance metadata provider not configured' }
        end

        def fetch_batch(token_ids)
          Array(token_ids).map do |token_id|
            { token_id: token_id, result: fetch(token_id) }
          end
        end

        def enabled?
          false
        end
      end
    end
  end
end
