# frozen_string_literal: true

module Metadata
  module InstanceMetadata
    # Base class for instance metadata providers.
    #
    # An instance metadata provider fetches metadata (name, description, image,
    # attributes) for individual NFT token instances.
    #
    # Subclasses must implement:
    #   - fetch(token_id, **opts)      → { success: bool, metadata: Hash | nil, error: String | nil }
    #   - fetch_batch(token_ids)       → Array<{ token_id:, result: }>
    #   - enabled?                     → Boolean
    #
    class BaseProvider
      def provider_key
        raise NotImplementedError, "#{self.class}#provider_key must be implemented"
      end

      def fetch(_token_id, **_opts)
        raise NotImplementedError, "#{self.class}#fetch must be implemented"
      end

      def fetch_batch(_token_ids)
        raise NotImplementedError, "#{self.class}#fetch_batch must be implemented"
      end

      def enabled?
        raise NotImplementedError, "#{self.class}#enabled? must be implemented"
      end

      # Returns a hash of provider capabilities.
      # Subclasses may override to declare supported features.
      def capabilities
        {}
      end
    end
  end
end
