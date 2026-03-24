# frozen_string_literal: true

require 'rails_helper'

RSpec.describe CatalogData::Item, type: :model do
  describe '#extra' do
    let(:item) do
      described_class.new(
        item_id: 80_001,
        item_type: 'weapon',
        enabled: true,
        extra_data: {
          'destructible' => false,
          'use_level' => 0,
          'quality' => []
        }
      )
    end

    it 'preserves explicit false values' do
      expect(item.extra('destructible', true)).to be(false)
    end

    it 'preserves explicit zero values' do
      expect(item.extra('use_level', 9)).to eq(0)
    end

    it 'returns the fallback only when the key is absent' do
      expect(item.extra('missing_key', 'fallback')).to eq('fallback')
    end
  end
end
