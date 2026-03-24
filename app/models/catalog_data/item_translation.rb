# frozen_string_literal: true

module CatalogData
  class ItemTranslation < ApplicationRecord
    belongs_to :item,
               class_name: 'CatalogData::Item',
               foreign_key: :item_id,
               inverse_of: :translations

    SUPPORTED_LOCALES = %w[zh zh-CN en ja ko].freeze

    validates :locale, presence: true
    validates :name, presence: true
    validates :locale, uniqueness: { scope: :item_id }
    validates :locale, inclusion: { in: SUPPORTED_LOCALES }

    before_save :update_translation_hash

    def calculate_translation_hash
      hash_data = {
        name: name,
        description: description
      }
      Digest::MD5.hexdigest(hash_data.to_json)
    end

    def normalized_locale
      case locale
      when 'zh-CN'
        'zh'
      else
        locale
      end
    end

    private

    def update_translation_hash
      self.translation_hash = calculate_translation_hash
    end
  end
end
