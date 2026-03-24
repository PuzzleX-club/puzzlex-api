# frozen_string_literal: true

module CatalogData
  class ApplicationRecord < ::ApplicationRecord
    self.abstract_class = true

    default_scope { order(created_at: :desc) }
  end
end
