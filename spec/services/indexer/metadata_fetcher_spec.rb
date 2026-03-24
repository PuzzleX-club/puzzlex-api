# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Indexer::MetadataFetcher do
  let(:fetcher) { described_class.new }
  let(:metadata_json) do
    {
      'name' => 'Rare Sword',
      'description' => 'A powerful weapon',
      'image' => 'https://example.com/sword.png',
      'background_color' => '#FF0000',
      'attributes' => [
        { 'trait_type' => 'Quality', 'value' => '5' },
        { 'trait_type' => 'WealthValue', 'value' => '100', 'display_type' => 'number' }
      ]
    }
  end

  describe '#parse_and_save' do
    let!(:indexer_item) { create(:indexer_item, id: '33') }
    let!(:instance) do
      create(:indexer_instance, id: 'token-33-01',
             item_record: indexer_item, item: '33',
             metadata_status: 'fetching')
    end

    it 'persists metadata record' do
      fetcher.parse_and_save(instance.id, indexer_item.id, metadata_json)

      saved = ItemIndexer::Metadata.find_by(instance_id: instance.id)
      expect(saved).to be_present
      expect(saved.name).to eq('Rare Sword')
      expect(saved.description).to eq('A powerful weapon')
      expect(saved.image).to eq('https://example.com/sword.png')
      expect(saved.background_color).to eq('#FF0000')
      expect(saved.raw_metadata).to eq(metadata_json)
    end

    it 'persists attribute records' do
      fetcher.parse_and_save(instance.id, indexer_item.id, metadata_json)

      attrs = ItemIndexer::Attribute.where(instance_id: instance.id)
      expect(attrs.count).to eq(2)
      expect(attrs.pluck(:trait_type)).to contain_exactly('Quality', 'WealthValue')
    end

    it 'replaces existing attributes on re-save' do
      fetcher.parse_and_save(instance.id, indexer_item.id, metadata_json)
      expect(ItemIndexer::Attribute.where(instance_id: instance.id).count).to eq(2)

      updated_json = metadata_json.merge('attributes' => [
        { 'trait_type' => 'NewTrait', 'value' => '42' }
      ])
      fetcher.parse_and_save(instance.id, indexer_item.id, updated_json)

      attrs = ItemIndexer::Attribute.where(instance_id: instance.id)
      expect(attrs.count).to eq(1)
      expect(attrs.first.trait_type).to eq('NewTrait')
    end

    it 'skips attributes with blank trait_type or value' do
      json_with_blanks = metadata_json.merge('attributes' => [
        { 'trait_type' => '', 'value' => '5' },
        { 'trait_type' => 'Quality', 'value' => nil },
        { 'trait_type' => 'Valid', 'value' => 'ok' }
      ])
      fetcher.parse_and_save(instance.id, indexer_item.id, json_with_blanks)

      attrs = ItemIndexer::Attribute.where(instance_id: instance.id)
      expect(attrs.count).to eq(1)
      expect(attrs.first.trait_type).to eq('Valid')
    end

    it 'handles metadata with no attributes' do
      json_no_attrs = metadata_json.except('attributes')
      fetcher.parse_and_save(instance.id, indexer_item.id, json_no_attrs)

      saved = ItemIndexer::Metadata.find_by(instance_id: instance.id)
      expect(saved).to be_present
      expect(ItemIndexer::Attribute.where(instance_id: instance.id).count).to eq(0)
    end

    it 'persists metadata from symbol-keyed provider payloads' do
      symbol_keyed_json = metadata_json.deep_symbolize_keys

      fetcher.parse_and_save(instance.id, indexer_item.id, symbol_keyed_json)

      saved = ItemIndexer::Metadata.find_by(instance_id: instance.id)
      expect(saved).to be_present
      expect(saved.name).to eq('Rare Sword')
      expect(saved.description).to eq('A powerful weapon')
      expect(saved.image).to eq('https://example.com/sword.png')
      expect(saved.raw_metadata).to include(
        'name' => 'Rare Sword',
        'description' => 'A powerful weapon',
        'image' => 'https://example.com/sword.png'
      )

      attrs = ItemIndexer::Attribute.where(instance_id: instance.id)
      expect(attrs.count).to eq(2)
      expect(attrs.pluck(:trait_type)).to contain_exactly('Quality', 'WealthValue')
    end
  end
end
