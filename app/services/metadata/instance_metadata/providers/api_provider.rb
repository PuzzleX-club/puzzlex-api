# frozen_string_literal: true

require 'net/http'
require 'json'

module Metadata
  module InstanceMetadata
    module Providers
      # API-based instance metadata provider.
      #
      # Fetches metadata via HTTP from a configurable API endpoint.
      # Does NOT persist to the database — that is handled by the
      # metadata persistence pipeline.
      #
      class ApiProvider < BaseProvider
        def provider_key
          'api'
        end

        def fetch(token_id, **_opts)
          return disabled_result unless enabled?

          metadata_json = fetch_from_api(token_id)

          if metadata_json
            { success: true, metadata: metadata_json, error: nil }
          else
            { success: false, metadata: nil, error: 'Failed to fetch metadata from API' }
          end
        rescue StandardError => e
          { success: false, metadata: nil, error: "#{e.class}: #{e.message}" }
        end

        def fetch_batch(token_ids)
          Array(token_ids).map do |token_id|
            result = fetch(token_id)
            sleep(fetch_interval) if fetch_interval > 0
            { token_id: token_id.to_s, result: result }
          end
        end

        def enabled?
          config.enabled
        rescue StandardError
          false
        end

        def capabilities
          { batch_fetch: true, rate_limit_aware: true }
        end

        private

        def config
          Rails.application.config.x.instance_metadata
        end

        def api_base_url
          config.api_base_url
        end

        def fetch_interval
          config.fetch_interval || 0
        end

        def disabled_result
          { success: false, metadata: nil, error: 'metadata fetching disabled' }
        end

        def fetch_from_api(token_id)
          url = "#{api_base_url}/metadata/#{token_id}"
          uri = URI.parse(url)

          Rails.logger.debug "[ApiProvider] 请求URL: #{url}"

          response = Net::HTTP.get_response(uri)

          case response.code
          when '200'
            data = JSON.parse(response.body)

            if (data.nil? || data.empty?) && Indexer::RateLimitHandler.empty_response_as_rate_limit?
              Indexer::RateLimitHandler.on_rate_limited!(reason: 'empty_response')
              Rails.logger.warn "[ApiProvider] 空数据视为限流 tokenId=#{token_id}"
              return nil
            end

            Indexer::RateLimitHandler.on_success!
            data
          when '429'
            retry_after = response['Retry-After']&.to_i || 60
            Indexer::RateLimitHandler.on_rate_limited!(retry_after: retry_after, reason: 'http_429')
            Rails.logger.warn "[ApiProvider] HTTP 429 限流 tokenId=#{token_id}, retry_after=#{retry_after}s"
            nil
          when '503'
            Indexer::RateLimitHandler.on_rate_limited!(retry_after: 30, reason: 'http_503')
            Rails.logger.warn "[ApiProvider] HTTP 503 服务过载 tokenId=#{token_id}"
            nil
          when '520', '521', '522', '523', '524', '525', '526', '527', '528', '529', '530'
            Indexer::RateLimitHandler.on_rate_limited!(retry_after: 60, reason: "cloudflare_#{response.code}")
            Rails.logger.warn "[ApiProvider] Cloudflare错误 #{response.code} tokenId=#{token_id}"
            nil
          else
            if Indexer::RateLimitHandler.simple_rate_limit_mode?
              Indexer::RateLimitHandler.on_rate_limited!(reason: "http_#{response.code}")
              Rails.logger.warn "[ApiProvider] 简单模式限流 HTTP #{response.code} tokenId=#{token_id}"
            else
              Rails.logger.error "[ApiProvider] HTTP错误 #{response.code}: #{response.message}"
            end
            nil
          end
        rescue Net::OpenTimeout, Net::ReadTimeout => e
          Indexer::RateLimitHandler.on_rate_limited!(retry_after: 30, reason: 'timeout')
          Rails.logger.warn "[ApiProvider] 请求超时 tokenId=#{token_id}: #{e.message}"
          nil
        rescue JSON::ParserError => e
          if Indexer::RateLimitHandler.simple_rate_limit_mode?
            Indexer::RateLimitHandler.on_rate_limited!(reason: 'json_parse_error')
            Rails.logger.warn "[ApiProvider] JSON解析失败视为限流 tokenId=#{token_id}"
          else
            Rails.logger.error "[ApiProvider] JSON解析失败: #{e.message}"
          end
          nil
        rescue StandardError => e
          if Indexer::RateLimitHandler.simple_rate_limit_mode?
            Indexer::RateLimitHandler.on_rate_limited!(reason: 'exception')
            Rails.logger.warn "[ApiProvider] 异常视为限流 tokenId=#{token_id}: #{e.message}"
          else
            Rails.logger.error "[ApiProvider] API请求失败: #{e.message}"
          end
          nil
        end
      end
    end
  end
end
