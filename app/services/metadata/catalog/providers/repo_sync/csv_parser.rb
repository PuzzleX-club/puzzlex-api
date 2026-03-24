# frozen_string_literal: true

require 'csv'

module Metadata
  module Catalog
    module Providers
      module RepoSync
        # Parses multi-language CSV files for items and recipes.
        #
        class CsvParser
          LANGUAGE_MAPPING = {
            'zh-CN' => 'zh',
            'en' => 'en',
            'ja' => 'ja',
            'ko' => 'ko'
          }.freeze

          class << self
            # Parse multi-language CSV contents.
            # @param csv_contents [Hash] { 'zh-CN' => csv_string, 'en' => csv_string }
            # @param file_type [String] 'Item' or 'Recipes'
            # @return [Array<Hash>]
            def parse_multi_language(csv_contents, file_type)
              return [] if csv_contents.empty?

              case file_type
              when 'Item'
                parse_items(csv_contents)
              when 'Recipes'
                parse_recipes(csv_contents)
              else
                raise ArgumentError, "Unsupported file type: #{file_type}"
              end
            end

            def parse_items(csv_contents)
              items = {}

              csv_contents.each do |locale, csv_content|
                locale_code = LANGUAGE_MAPPING[locale] || locale

                rows = parse_csv_with_bom(csv_content)
                Rails.logger.info "[RepoSync::CsvParser] parsing #{locale} items, #{rows.count} rows"

                rows.each_with_index do |row, index|
                  item_id = row['id-int'].to_i
                  next if item_id == 0

                  items[item_id] ||= { item_id: item_id, translations: {} }

                  items[item_id][:translations][locale_code] = {
                    name: row['name-string']&.strip || '',
                    description: row['desc-string']&.strip || ''
                  }

                  # Only parse non-translation fields from the first locale
                  next if items[item_id][:parsed]

                  items[item_id].merge!(
                    parsed: true,
                    icon: row['icon-string']&.strip,
                    item_type: parse_integer(row['type-int']),
                    can_mint: parse_boolean(row['canMint-int']),
                    sellable: parse_boolean(row['sellable-bool']),
                    extra_data: {
                      'sub_type' => parse_integer(row['subType-int']),
                      'quality' => parse_array(row['quality-int[]']),
                      'use_level' => parse_integer(row['useLv-int']),
                      'wealth_value' => parse_integer(row['wealthValue-int']),
                      'drop_scenes' => parse_array(row['canDropScene-int[]']),
                      'talent_ids' => parse_array(row['talentId-int[]']),
                      'booth_fees' => parse_2d_array(row['boothFees-int[][]']),
                      'destructible' => parse_boolean(row['destructible-bool']),
                      'given_skill_id' => parse_integer(row['givenSkillId-int']),
                      'on_chain_delay' => parse_integer(row['onChainDelay-int']),
                      'resource_instructions' => parse_array(row['resourceInstructions-int[]']),
                      'token_task_level' => parse_array(row['tokenTaskLevel-int[]']),
                      'token_task_refresh_type' => parse_integer(row['tokenTaskRefreshType-int']),
                      'user_type' => parse_integer(row['userType-int'])
                    }
                  )
                rescue StandardError => e
                  Rails.logger.error "[RepoSync::CsvParser] item row [#{index}] failed: #{e.message}"
                  Rails.logger.error "[RepoSync::CsvParser] row: #{row.inspect}"
                end
              rescue StandardError => e
                Rails.logger.error "[RepoSync::CsvParser] item CSV (#{locale}) failed: #{e.message}"
              end

              Rails.logger.info "[RepoSync::CsvParser] items parsed: #{items.size}"
              items.values
            end

            def parse_recipes(csv_contents)
              recipes = {}

              csv_contents.each do |locale, csv_content|
                locale_code = LANGUAGE_MAPPING[locale] || locale

                rows = parse_csv_with_bom(csv_content)
                Rails.logger.info "[RepoSync::CsvParser] parsing #{locale} recipes, #{rows.count} rows"

                rows.each_with_index do |row, index|
                  recipe_id = row['id-int'].to_i
                  next if recipe_id == 0

                  recipes[recipe_id] ||= { recipe_id: recipe_id, translations: {} }

                  recipes[recipe_id][:translations][locale_code] = {
                    name: row['name-string']&.strip || '',
                    description: row['desc-string']&.strip || ''
                  }

                  next if recipes[recipe_id][:parsed]

                  recipes[recipe_id].merge!(
                    parsed: true,
                    icon: row['icon-string']&.strip,
                    classify_level: parse_integer(row['classifyLevel-int']),
                    display_type: parse_integer(row['displayType-int']),
                    level: parse_integer(row['level-int']),
                    proficiency: parse_integer(row['proficiency-int']),
                    recipes_sort: parse_integer(row['recipesSort-int']),
                    source_text: parse_integer(row['sourceText-int']),
                    time_cost: parse_integer(row['timeCost-int']),
                    times_limit: parse_integer(row['timesLimit-int']),
                    recipe_type: parse_integer(row['type-int']),
                    unlock_condition: parse_integer(row['unlockCondition-int']),
                    unlock_type: parse_integer(row['unlockType-int']),
                    use_ditamin: parse_integer(row['useDitamin-int']),
                    use_token: parse_integer(row['useToken-int']),
                    materials: parse_2d_array(row['matItemId-int[][]']),
                    products: parse_recipe_products(row['productId-int[][]'])
                  )
                rescue StandardError => e
                  Rails.logger.error "[RepoSync::CsvParser] recipe row [#{index}] failed: #{e.message}"
                  Rails.logger.error "[RepoSync::CsvParser] row: #{row.inspect}"
                end
              rescue StandardError => e
                Rails.logger.error "[RepoSync::CsvParser] recipe CSV (#{locale}) failed: #{e.message}"
              end

              Rails.logger.info "[RepoSync::CsvParser] recipes parsed: #{recipes.size}"
              recipes.values
            end

            private

            def parse_csv_with_bom(content)
              content = content.gsub("\xEF\xBB\xBF", '')
              CSV.parse(content, headers: true)
            end

            def parse_integer(value)
              return 0 if value.nil? || value.strip.empty?

              value.strip.to_i
            end

            def parse_boolean(value)
              case value.to_s.strip.downcase
              when 'true', '1', 'yes', 'y'
                true
              when 'false', '0', 'no', 'n'
                false
              else
                value.to_i > 0
              end
            end

            def parse_array(str)
              return [] if str.nil? || str.strip.empty? || str == '0'

              cleaned = str.gsub(/["'\[\]]/, '').strip
              return [] if cleaned.empty?

              cleaned.split(',').map(&:strip).reject(&:empty?).map(&:to_i)
            end

            def parse_2d_array(str)
              return [] if str.nil? || str.strip.empty?

              cleaned = str.gsub(/["'\[\]]/, '').strip
              return [] if cleaned.empty?

              rows = cleaned.split(';').map(&:strip).reject(&:empty?)
              rows.map do |row|
                cols = row.split(',').map(&:strip).reject(&:empty?)
                cols.map(&:to_i)
              end
            end

            def parse_recipe_products(str)
              return [] if str.nil? || str.strip.empty?

              cleaned = str.gsub(/["'\[\]]/, '').strip
              return [] if cleaned.empty?

              rows = cleaned.split(';').map(&:strip).reject(&:empty?)
              rows.map do |row|
                parts = row.split(',').map(&:strip).reject(&:empty?)
                {
                  item_id: parts[0]&.to_i,
                  quality: parts[1]&.to_i || 1,
                  quantity: parts[2]&.to_i || 1,
                  weight: parts[3]&.to_i || 0,
                  product_type: parts[4]&.to_i || 0
                }
              end
            end
          end
        end
      end
    end
  end
end
