# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Admin::MarketsController', type: :request do
  let!(:item) do
    CatalogData::Item.create!(
      item_id: Faker::Number.unique.between(from: 91_000, to: 91_999),
      item_type: 'weapon',
      enabled: true,
      sellable: true,
      can_mint: false,
      source_hash: SecureRandom.hex(32)
    )
  end

  around do |example|
    original_provider = Rails.application.config.x.catalog.provider
    original_skip_auth = Rails.application.config.x.admin.skip_auth
    original_admin_features_enabled = Rails.application.config.admin_features_enabled

    Rails.application.config.x.catalog.provider = :none
    Rails.application.config.x.admin.skip_auth = true
    Rails.application.config.admin_features_enabled = true
    Rails.application.reload_routes!
    Metadata::Catalog::ProviderRegistry.reset!

    example.run
  ensure
    Rails.application.config.x.catalog.provider = original_provider
    Rails.application.config.x.admin.skip_auth = original_skip_auth
    Rails.application.config.admin_features_enabled = original_admin_features_enabled
    Rails.application.reload_routes!
    Metadata::Catalog::ProviderRegistry.reset!
  end

  describe 'POST /api/admin/markets' do
    it 'rejects market creation when marketplace capability is disabled' do
      post '/api/admin/markets', params: { item_id: item.item_id }, as: :json

      expect(response).to have_http_status(:unprocessable_entity)

      json = JSON.parse(response.body)
      expect(json['message']).to eq('Catalog provider does not support marketplace')
    end
  end
end
