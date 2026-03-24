# frozen_string_literal: true

require 'net/http'
require 'uri'
require 'timeout'

module Metadata
  module Catalog
    module Providers
      module RepoSync
        # Fetches CSV files from a GitHub repository.
        #
        # Reads all config from config.x.catalog.providers.repo_sync.
        #
        class Fetcher
          class << self
            # Fetch a file for all configured languages.
            # @param file_type [String] 'Item' or 'Recipes'
            # @return [Hash] { contents: { locale => csv_string }, errors: { locale => msg } }
            def fetch_all_languages(file_type)
              contents = {}
              errors = {}
              c = config

              c[:supported_languages].each do |lang|
                url = build_file_url(file_type, lang)
                Rails.logger.info "[RepoSync::Fetcher] downloading #{file_type} #{lang}..." if c[:debug]
                contents[lang] = fetch_csv(url)
                Rails.logger.info "[RepoSync::Fetcher] #{file_type} #{lang} OK, #{contents[lang].bytesize} bytes"
              rescue StandardError => e
                Rails.logger.error "[RepoSync::Fetcher] #{file_type} #{lang} failed: #{e.message}"
                errors[lang] = e.message
              end

              raise "All language downloads failed: #{errors}" if contents.empty?

              { contents: contents, errors: errors }
            end

            # Fetch a single file.
            def fetch_file(file_type, language = 'zh-CN')
              url = build_file_url(file_type, language)
              fetch_csv(url)
            end

            # MD5 hash of a fetched file (for change detection).
            def fetch_file_hash(file_type, language = 'zh-CN')
              content = fetch_file(file_type, language)
              Digest::MD5.hexdigest(content) if content
            end

            private

            def config
              Rails.application.config.x.catalog.providers.repo_sync
            end

            def build_file_url(file_type, language)
              c = config
              base_url = "https://raw.githubusercontent.com/#{c[:repo]}/#{c[:branch]}"
              filename = file_type == 'Item' ? c[:item_filename] : c[:recipes_filename]
              file_path = "#{c[:data_dir]}/#{language}/Csv/#{filename}"
              "#{base_url}/#{file_path}"
            end

            def fetch_csv(url)
              c = config
              uri = URI(url)
              http = Net::HTTP.new(uri.host, uri.port)
              http.use_ssl = true
              http.read_timeout = c[:timeout]
              http.open_timeout = 10
              http.ssl_version = :TLSv1_2
              http.verify_mode = OpenSSL::SSL::VERIFY_PEER

              request = Net::HTTP::Get.new(uri)
              request['User-Agent'] = 'PuzzleX-CatalogSync/1.0'
              request['Accept'] = 'text/csv, text/plain, */*'

              github_token = c[:github_token]
              request['Authorization'] = "Bearer #{github_token}" if github_token

              Timeout.timeout(c[:timeout]) do
                response = http.request(request)

                if response.is_a?(Net::HTTPSuccess)
                  content = response.body
                  content.force_encoding('UTF-8')
                  raise 'Downloaded content is not valid CSV' unless content.include?("\n")

                  content
                else
                  raise "HTTP #{response.code}: #{response.message}"
                end
              end
            rescue Timeout::Error
              raise "Download timeout (#{c[:timeout]}s)"
            rescue StandardError => e
              c = config
              Rails.logger.error "[RepoSync::Fetcher] network error #{url}: #{e.class.name} - #{e.message}"
              Rails.logger.error "[RepoSync::Fetcher] repo=#{c[:repo]}, branch=#{c[:branch]}" if c[:debug]
              raise
            end
          end
        end
      end
    end
  end
end
