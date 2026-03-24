# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Blockchain::TokenIdParser do
  subject(:parser) { described_class.new(config: parser_config) }

  let(:parser_config) do
    ActiveSupport::OrderedOptions.new.tap do |cfg|
      cfg.mode = mode
      cfg.embedded_prefix = embedded_prefix
      cfg.erc20_prefix = erc20_prefix
      cfg.hash_bytes = hash_bytes
      cfg.quality_bytes = quality_bytes
    end
  end

  let(:mode) { 'embedded' }
  let(:embedded_prefix) { '0x10' }
  let(:erc20_prefix) { '0x20' }
  let(:hash_bytes) { 16 }
  let(:quality_bytes) { 1 }

  describe '#item_id' do
    it 'parses short embedded token ids' do
      token_id = [0x10, 0x12, 0x34, 0x02].pack('C*').unpack1('H*').to_i(16).to_s

      expect(parser.item_id(token_id)).to eq('4660')
    end

    it 'parses long embedded token ids' do
      bytes = [0x10] + Array.new(16, 0xaa) + [0x7b, 0x03]
      token_id = bytes.pack('C*').unpack1('H*').to_i(16).to_s

      expect(parser.item_id(token_id)).to eq('123')
      expect(parser.quality_hex(token_id)).to eq('0x3')
    end

    it 'parses erc20-prefixed token ids' do
      bytes = [0x20] + [0xde, 0xad, 0xbe, 0xef]
      token_id = bytes.pack('C*').unpack1('H*').to_i(16).to_s

      expect(parser.item_id(token_id)).to eq('3735928559')
    end

    context 'when parser mode is identity' do
      let(:mode) { 'identity' }

      it 'returns the token id itself as item id' do
        expect(parser.item_id('1048833')).to eq('1048833')
        expect(parser.item_id('0x10')).to eq('16')
      end

      it 'returns zero quality for identity mode' do
        expect(parser.quality_hex('1048833')).to eq('0x0')
      end
    end

    context 'when parser mode is custom' do
      let(:mode) { 'custom' }

      context 'with default stub' do
        it 'raises NotImplementedError for item_id' do
          expect { parser.item_id('12345') }.to raise_error(NotImplementedError, /not implemented/)
        end

        it 'raises NotImplementedError for item_id_int' do
          expect { parser.item_id_int('12345') }.to raise_error(NotImplementedError, /not implemented/)
        end

        it 'raises NotImplementedError for quality' do
          expect { parser.quality('12345') }.to raise_error(NotImplementedError, /not implemented/)
        end

        it 'raises NotImplementedError for quality_hex' do
          expect { parser.quality_hex('12345') }.to raise_error(NotImplementedError, /not implemented/)
        end

        it 'returns nil for quality_hex with blank token_id' do
          expect(parser.quality_hex(nil)).to be_nil
          expect(parser.quality_hex('')).to be_nil
        end
      end

      context 'with project-supplied parser' do
        let(:custom_impl) do
          Class.new(Blockchain::CustomTokenIdParser) do
            def item_id(token_id)
              token_id.to_s.reverse
            end

            def item_id_int(token_id)
              999
            end

            def quality(_token_id)
              42
            end
          end
        end

        before do
          allow(Blockchain::CustomTokenIdParser).to receive(:new).and_return(custom_impl.new)
        end

        it 'delegates item_id to the custom parser' do
          expect(parser.item_id('12345')).to eq('54321')
        end

        it 'delegates item_id_int to the custom parser override' do
          expect(parser.item_id_int('12345')).to eq(999)
        end

        it 'delegates quality to the custom parser' do
          expect(parser.quality('12345')).to eq(42)
        end

        it 'delegates quality_hex to the custom parser' do
          expect(parser.quality_hex('12345')).to eq('0x2a')
        end
      end
    end
  end
end
