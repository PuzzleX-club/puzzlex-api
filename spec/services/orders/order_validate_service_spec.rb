# frozen_string_literal: true

require 'rails_helper'
require 'ostruct'

RSpec.describe Orders::OrderValidateService do
  let(:offerer) { '0xabc0000000000000000000000000000000000123' }
  let(:user) { OpenStruct.new(address: offerer) }
  let(:service) { described_class.new(user, { parameters: {} }) }

  describe '#existing_order_token_required' do
    let(:token_id) { '268724496' }

    it 'counts active + matching only, excludes over_matched' do
      create(:trading_order,
             offerer: offerer,
             order_direction: 'List',
             offer_identifier: token_id,
             onchain_status: 'validated',
             offchain_status: 'active',
             offer_start_amount: 3,
             offer_end_amount: 3)

      create(:trading_order,
             offerer: offerer,
             order_direction: 'List',
             offer_identifier: token_id,
             onchain_status: 'validated',
             offchain_status: 'matching',
             offer_start_amount: 2,
             offer_end_amount: 2)

      create(:trading_order,
             offerer: offerer,
             order_direction: 'List',
             offer_identifier: token_id,
             onchain_status: 'validated',
             offchain_status: 'over_matched',
             offer_start_amount: 5,
             offer_end_amount: 5)

      required = service.send(:existing_order_token_required, offerer, token_id)

      expect(required).to eq(5)
    end

    it 'returns 0 when token_id is blank' do
      expect(service.send(:existing_order_token_required, offerer, nil)).to eq(0)
      expect(service.send(:existing_order_token_required, offerer, '')).to eq(0)
    end
  end

  describe '#existing_order_currency_required' do
    let(:currency_address) { '0xdef0000000000000000000000000000000000456' }

    it 'counts active + matching only, excludes over_matched' do
      create(:trading_order,
             offerer: offerer,
             order_direction: 'Offer',
             offer_token: currency_address,
             onchain_status: 'validated',
             offchain_status: 'active',
             consideration_start_amount: 100,
             consideration_end_amount: 100)

      create(:trading_order,
             offerer: offerer,
             order_direction: 'Offer',
             offer_token: currency_address,
             onchain_status: 'partially_filled',
             offchain_status: 'matching',
             consideration_start_amount: 50,
             consideration_end_amount: 50)

      create(:trading_order,
             offerer: offerer,
             order_direction: 'Offer',
             offer_token: currency_address,
             onchain_status: 'validated',
             offchain_status: 'over_matched',
             consideration_start_amount: 999,
             consideration_end_amount: 999)

      required = service.send(:existing_order_currency_required, offerer, currency_address)

      expect(required).to eq(150)
    end
  end

  describe '#validate_collection_offer_single_amount' do
    let(:criteria_hash) { "0x#{'a' * 64}" }
    let(:base_order_params) do
      {
        parameters: {
          consideration: [
            {
              token: '0xnft',
              identifierOrCriteria: criteria_hash,
              startAmount: '1',
              endAmount: '1'
            }
          ]
        }
      }
    end
    let(:service) { described_class.new(user, base_order_params) }

    before do
      service.instance_variable_set(:@errors, [])
      service.instance_variable_set(
        :@validation_details,
        { passed_steps: [], failed_steps: [] }
      )
      allow(service).to receive(:infer_order_type).and_return('Offer')
      allow(service).to receive(:nft_token?) { |token| token == '0xnft' }
    end

    it 'passes when collection buy quantity is 1' do
      expect(service.send(:validate_collection_offer_single_amount)).to be(true)
      expect(service.errors).to be_empty
    end

    it 'fails when collection buy quantity is not 1' do
      base_order_params[:parameters][:consideration][0][:startAmount] = '2'
      base_order_params[:parameters][:consideration][0][:endAmount] = '2'

      expect(service.send(:validate_collection_offer_single_amount)).to be(false)
      expect(service.errors).to include('Collection 买单仅支持数量 1')
    end

    it 'skips when not a collection buy order' do
      allow(service).to receive(:infer_order_type).and_return('List')

      expect(service.send(:validate_collection_offer_single_amount)).to be(true)
      expect(service.errors).to be_empty
    end
  end
end
