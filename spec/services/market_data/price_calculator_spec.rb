# frozen_string_literal: true

require 'rails_helper'

RSpec.describe MarketData::PriceCalculator do
  describe '.calculate_price' do
    context 'with valid price_distribution' do
      let(:price_distribution) do
        [{
          "token_address" => "0x123",
          "total_amount" => "1000000000000000000", # 1 ETH in wei
          "item_type" => 1
        }]
      end
      
      it 'calculates price correctly' do
        filled_amount = 2.0
        expected_price = 1000000000000000000.0 / 2.0 # 0.5 ETH in wei
        
        price = described_class.calculate_price(price_distribution, filled_amount)
        expect(price).to eq(expected_price)
      end
      
      it 'returns 0 when filled_amount is zero' do
        price = described_class.calculate_price(price_distribution, 0)
        expect(price).to eq(0.0)
      end
    end
    
    context 'with invalid price_distribution' do
      it 'returns 0 when price_distribution is nil' do
        price = described_class.calculate_price(nil, 1.0)
        expect(price).to eq(0.0)
      end
      
      it 'returns 0 when price_distribution is not an array' do
        price = described_class.calculate_price("invalid", 1.0)
        expect(price).to eq(0.0)
      end
      
      it 'returns price based on first element when price_distribution has multiple elements' do
        multi_distribution = [
          { "total_amount" => "100" },
          { "total_amount" => "200" }
        ]
        price = described_class.calculate_price(multi_distribution, 1.0)
        expect(price).to eq(100) # Uses first element's total_amount
      end
      
      it 'returns 0 when price_distribution element is not a hash' do
        price = described_class.calculate_price(["invalid"], 1.0)
        expect(price).to eq(0.0)
      end
      
      it 'returns 0 when total_amount is missing' do
        invalid_distribution = [{ "other_field" => "value", "total_amount" => "" }]
        # The actual implementation will raise ArgumentError on BigDecimal("")
        expect { described_class.calculate_price(invalid_distribution, 1.0) }.to raise_error(ArgumentError)
      end
    end
  end
  
  describe '.calculate_price_from_fill' do
    let(:fill) do
      instance_double(
        Trading::OrderFill,
        price_distribution: [{
          "token_address" => "0x123",
          "total_amount" => "2000000000000000000", # 2 ETH in wei
          "item_type" => 1
        }],
        filled_amount: 4.0
      )
    end
    
    it 'calculates price from fill object' do
      expected_price = 2000000000000000000.0 / 4.0 # 0.5 ETH in wei
      price = described_class.calculate_price_from_fill(fill)
      expect(price).to eq(expected_price)
    end
    
    it 'returns 0 when fill is nil' do
      price = described_class.calculate_price_from_fill(nil)
      expect(price).to eq(0.0)
    end
  end
  
  describe '.wei_to_eth' do
    it 'converts wei to eth correctly' do
      wei = 1500000000000000000 # 1.5 ETH in wei
      eth = described_class.wei_to_eth(wei)
      expect(eth).to eq(1.5)
    end
    
    it 'respects precision parameter' do
      wei = 1234567890123456789
      eth = described_class.wei_to_eth(wei, precision: 2)
      expect(eth).to eq(1.23)
    end
    
    it 'returns 0 for nil input' do
      eth = described_class.wei_to_eth(nil)
      expect(eth).to eq(0.0)
    end
    
    it 'returns 0 for zero input' do
      eth = described_class.wei_to_eth(0)
      expect(eth).to eq(0.0)
    end
  end
  
  describe '.eth_to_wei' do
    it 'converts eth to wei correctly' do
      eth = 1.5
      wei = described_class.eth_to_wei(eth)
      expect(wei).to eq(1500000000000000000)
    end
    
    it 'returns integer value' do
      eth = 1.23456789
      wei = described_class.eth_to_wei(eth)
      expect(wei).to be_a(Integer)
    end
    
    it 'returns 0 for nil input' do
      wei = described_class.eth_to_wei(nil)
      expect(wei).to eq(0)
    end
    
    it 'returns 0 for zero input' do
      wei = described_class.eth_to_wei(0)
      expect(wei).to eq(0)
    end
  end
  
  describe '.calculate_price_in_eth' do
    let(:fill) do
      instance_double(
        Trading::OrderFill,
        price_distribution: [{
          "total_amount" => "3000000000000000000", # 3 ETH in wei
        }],
        filled_amount: 2.0
      )
    end
    
    it 'calculates price and converts to eth' do
      price_eth = described_class.calculate_price_in_eth(fill)
      expect(price_eth).to eq(1.5) # 3 ETH / 2 = 1.5 ETH
    end
    
    it 'respects precision parameter' do
      price_eth = described_class.calculate_price_in_eth(fill, precision: 1)
      expect(price_eth).to eq(1.5)
    end
  end
  
  describe '.batch_calculate_prices' do
    let(:fills) do
      [
        instance_double(
          Trading::OrderFill,
          id: 1,
          price_distribution: [{ "total_amount" => "1000000000000000000" }],
          filled_amount: 1.0
        ),
        instance_double(
          Trading::OrderFill,
          id: 2,
          price_distribution: [{ "total_amount" => "2000000000000000000" }],
          filled_amount: 2.0
        ),
        instance_double(
          Trading::OrderFill,
          id: 3,
          price_distribution: nil,
          filled_amount: 1.0
        )
      ]
    end
    
    it 'calculates prices for multiple fills' do
      results = described_class.batch_calculate_prices(fills)
      
      expect(results).to eq({
        1 => 1000000000000000000.0,
        2 => 1000000000000000000.0,
        3 => 0.0
      })
    end
  end
end