# frozen_string_literal: true

module Metadata
  module InstanceMetadata
    module Providers
      # Example instance metadata provider for OSS demo / smoke testing.
      #
      # Reads static JSON fixtures from backend/examples/instance_metadata/
      # and returns metadata in the same shape as ApiProvider.
      #
      # No external API, no private dependencies required.
      #
      class ExampleProvider < BaseProvider
        def provider_key
          'example'
        end

        def fetch(token_id, **_opts)
          data = instances_index[token_id.to_s]
          return { success: false, metadata: nil, error: 'not found in example data' } unless data

          { success: true, metadata: build_metadata(data), error: nil }
        end

        def fetch_batch(token_ids)
          Array(token_ids).map do |token_id|
            { token_id: token_id.to_s, result: fetch(token_id) }
          end
        end

        def enabled?
          true
        end

        private

        def instances_index
          @instances_index ||= instances_data.index_by { |d| d['token_id'].to_s }
        end

        def instances_data
          @instances_data ||= load_json('instances.json')
        end

        def load_json(filename)
          path = Rails.root.join('examples', 'instance_metadata', filename)
          return [] unless File.exist?(path)

          JSON.parse(File.read(path))
        rescue JSON::ParserError => e
          Rails.logger.error "[ExampleInstanceMetadataProvider] Failed to parse #{filename}: #{e.message}"
          []
        end

        def build_metadata(data)
          {
            name: data['name'],
            description: data['description'],
            image: data['image'],
            attributes: (data['attributes'] || []).map do |attr|
              {
                trait_type: attr['trait_type'],
                value: attr['value'],
                display_type: attr['display_type']
              }.compact
            end
          }
        end
      end
    end
  end
end
