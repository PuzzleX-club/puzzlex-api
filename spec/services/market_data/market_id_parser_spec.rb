# spec/services/market_data/market_id_parser_spec.rb
require 'rails_helper'

RSpec.describe MarketData::MarketIdParser, type: :service do
  # The PRICE_TOKEN_TYPE_MAP is loaded from environment variables at boot time.
  # Stub it with known values so specs are deterministic regardless of env config.
  let(:test_token_map) do
    {
      "00" => { symbol: "ETH", address: "0x0000000000000000000000000000000000000000" },
      "01" => { symbol: "USDC", address: "0xA0b86991c6218b36c1d19d4a2e9eb0ce3606eb48" }
    }
  end

  before do
    stub_const("Rails.application.config.x.blockchain.price_token_type_map", test_token_map)
  end

  describe "#initialize" do
    context "when only market_id is given" do
      context "and market_id is too short" do
        let(:market_id) { "A" } # only 1 char
        subject { described_class.new(market_id: market_id) }

        it "sets @item_id and @price_token_type_key to nil" do
          expect(subject.item).to be_nil
          expect(subject.price_symbol).to be_nil
          expect(subject.price_address).to be_nil
        end
      end

      context "and market_id is exactly 2 chars" do
        let(:market_id) { "00" }  # last two chars only => item_id=""
        subject { described_class.new(market_id: market_id) }

        it "item is nil, but price_address is parsed from PRICE_TOKEN_TYPE_MAP" do
          expect(subject.item).to be_nil
          expect(subject.price_symbol).to eq("ETH")
          expect(subject.price_address).to eq("0x0000000000000000000000000000000000000000")
        end
      end

      context "and market_id has more than 2 chars" do
        context "and the last two chars are a known token code" do
          let(:market_id) { "12300" }
          subject { described_class.new(market_id: market_id) }

          it "correctly parses item_id and price token info" do
            expect(subject.item).to eq(123)
            expect(subject.price_symbol).to eq("ETH")
            expect(subject.price_address).to eq("0x0000000000000000000000000000000000000000")
          end
        end

        context "and the last two chars are unknown token code" do
          let(:market_id) { "123ZZ" }
          subject { described_class.new(market_id: market_id) }

          it "parses item_id but no price symbol/address" do
            expect(subject.item).to eq(123)
            expect(subject.price_symbol).to be_nil
            expect(subject.price_address).to be_nil
          end
        end
      end
    end

    context "when item_id and price_address are provided" do
      let(:item_id)        { 999 }
      let(:price_address)  { "0xA0b86991c6218b36c1d19d4a2e9eb0ce3606eb48" }
      subject { described_class.new(item_id: item_id, price_address: price_address) }

      it "parses them into item + price_token_type_key based on PRICE_TOKEN_TYPE_MAP" do
        expect(subject.item).to eq(999)
        expect(subject.price_symbol).to eq("USDC")
        expect(subject.price_address).to eq("0xA0b86991c6218b36c1d19d4a2e9eb0ce3606eb48")
      end
    end

    context "when neither market_id nor (item_id + price_address) is given" do
      subject { described_class.new }

      it "all fields are nil" do
        expect(subject.item).to be_nil
        expect(subject.price_symbol).to be_nil
        expect(subject.price_address).to be_nil
      end
    end

    describe "internally calling parse_market_id" do
      it "handles typical market_id usage" do
        parser = described_class.new(market_id: "45601")
        expect(parser.item).to eq(456)
        # "01" maps to USDC in our test token map
        expect(parser.price_symbol).to eq("USDC")
      end
    end
  end
end
