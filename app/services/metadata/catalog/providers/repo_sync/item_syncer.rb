# frozen_string_literal: true

module Metadata
  module Catalog
    module Providers
      module RepoSync
        # Persists parsed item data to CatalogData::Item and translations.
        #
        class ItemSyncer
          class << self
            # Sync items from parsed CSV contents.
            # @param csv_contents [Hash] { locale => csv_string }
            # @return [Hash] stats
            def sync(csv_contents)
              items_data = CsvParser.parse_multi_language(csv_contents, 'Item')
              stats = { created: 0, updated: 0, unchanged: 0, translations: { created: 0, updated: 0 }, errors: [] }

              items_data.each do |item_data|
                sync_single_item(item_data, stats)
              rescue StandardError => e
                Rails.logger.error "[RepoSync::ItemSyncer] item ##{item_data[:item_id]} failed: #{e.message}"
                stats[:errors] << { item_id: item_data[:item_id], error: e.message }
              end

              disable_absent_items(items_data, stats)

              Rails.logger.info "[RepoSync::ItemSyncer] done: created=#{stats[:created]} updated=#{stats[:updated]} " \
                                "unchanged=#{stats[:unchanged]} disabled=#{stats[:disabled]} errors=#{stats[:errors].size}"
              stats
            end

            private

            def sync_single_item(item_data, stats)
              item = CatalogData::Item.find_or_initialize_by(item_id: item_data[:item_id])

              base_attributes = item_data.except(:translations, :parsed, :item_id)

              old_hash = item.source_hash
              item.assign_attributes(base_attributes)
              new_hash = item.calculate_source_hash

              if item.new_record?
                item.save!
                stats[:created] += 1
              elsif old_hash != new_hash
                item.save!
                stats[:updated] += 1
              else
                stats[:unchanged] += 1
              end

              translation_stats = sync_translations(item, item_data[:translations])
              stats[:translations][:created] += translation_stats[:created]
              stats[:translations][:updated] += translation_stats[:updated]
            end

            def sync_translations(item, translations)
              stats = { created: 0, updated: 0 }

              translations.each do |locale, attrs|
                translation = item.translations.find_or_initialize_by(locale: locale)

                old_hash = translation.translation_hash
                translation.assign_attributes(attrs)
                new_hash = translation.calculate_translation_hash

                if translation.new_record?
                  translation.save!
                  stats[:created] += 1
                elsif old_hash != new_hash
                  translation.save!
                  stats[:updated] += 1
                end
              end

              stats
            end

            def disable_absent_items(items_data, stats)
              item_ids_in_repo = items_data.map { |item| item[:item_id] }
              disabled_count = CatalogData::Item
                .where.not(item_id: item_ids_in_repo)
                .where(enabled: true)
                .update_all(enabled: false, updated_at: Time.current)

              Rails.logger.info "[RepoSync::ItemSyncer] disabled #{disabled_count} absent items" if disabled_count > 0
              stats[:disabled] = disabled_count
            end
          end
        end
      end
    end
  end
end
