# frozen_string_literal: true

# CatalogData — generic namespace for static catalog models.
#
# This is the canonical application namespace for catalog data models.
# The underlying database tables remain unchanged, but app code should
# only reference CatalogData::*.
#
# Usage:
#   CatalogData::Item.find_by(item_id: 42)
#   CatalogData::Recipe.where(enabled: true)
#
module CatalogData
  def self.table_name_prefix
    'catalog_'
  end
end
