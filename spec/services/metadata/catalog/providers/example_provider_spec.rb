# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Metadata::Catalog::Providers::ExampleProvider do
  describe Metadata::Catalog::Providers::ExampleProvider::ExampleItem do
    subject(:item) do
      described_class.new(
        item_id: 80_001,
        icon: nil,
        item_type: 'weapon',
        can_mint: true,
        sellable: true,
        enabled: true,
        source_hash: 'hash',
        extra_data: {
          'destructible' => false,
          'use_level' => 0
        },
        translations: [],
        updated_at: Time.current
      )
    end

    it 'preserves explicit false values' do
      expect(item.extra('destructible', true)).to be(false)
    end

    it 'preserves explicit zero values' do
      expect(item.extra('use_level', 9)).to eq(0)
    end
  end
end
