# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Blockchain::CustomTokenIdParser do
  subject(:parser) { described_class.new }

  describe '#item_id' do
    it 'raises NotImplementedError' do
      expect { parser.item_id('12345') }.to raise_error(NotImplementedError, /not implemented/)
    end
  end

  describe '#item_id_int' do
    it 'raises NotImplementedError because item_id is not implemented' do
      expect { parser.item_id_int('12345') }.to raise_error(NotImplementedError)
    end
  end

  describe '#quality' do
    it 'raises NotImplementedError' do
      expect { parser.quality('12345') }.to raise_error(NotImplementedError, /not implemented/)
    end
  end

  describe '#quality_hex' do
    it 'raises NotImplementedError because quality is not implemented' do
      expect { parser.quality_hex('12345') }.to raise_error(NotImplementedError)
    end
  end

  context 'when subclassed with a project implementation' do
    let(:project_parser_class) do
      Class.new(described_class) do
        def item_id(token_id)
          token_id.to_s
        end

        def quality(_token_id)
          1
        end
      end
    end

    subject(:parser) { project_parser_class.new }

    it 'returns project-defined item_id' do
      expect(parser.item_id('999')).to eq('999')
    end

    it 'returns project-defined item_id_int via inherited method' do
      expect(parser.item_id_int('999')).to eq(999)
    end

    it 'returns project-defined quality' do
      expect(parser.quality('999')).to eq(1)
    end

    it 'returns quality_hex via inherited method' do
      expect(parser.quality_hex('999')).to eq('0x1')
    end
  end
end
