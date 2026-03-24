# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Matching::State::OrderPreValidator, type: :service do
  before do
    allow(Redis).to receive(:current).and_return(double('Redis',
      keys: [],
      get: nil,
      set: true,
      setex: true
    ))
    allow(ActionCable.server).to receive(:broadcast)
    allow(Jobs::Matching::Worker).to receive(:perform_in)
  end

  subject(:validator) { described_class.new }

  # Stub external dependencies by default
  before do
    allow(Matching::OverMatch::Detection).to receive(:check_order_balance_and_approval)
      .and_return({ sufficient: true })
    allow(Seaport::SignatureService).to receive(:validate_signature_with_details)
      .and_return({ valid: true, details: {} })
    allow_any_instance_of(Orders::ZoneValidationService).to receive(:validate)
      .and_return({ success: true })
  end

  describe '#validate - expiration checks' do
    context 'when order has not yet started' do
      it 'returns not_yet_valid' do
        order = build(:trading_order,
                      start_time: (Time.current + 1.hour).to_i.to_s,
                      end_time: (Time.current + 7.days).to_i.to_s)
        result = validator.validate(order)

        expect(result[:valid]).to be false
        expect(result[:reason]).to eq('not_yet_valid')
      end
    end

    context 'when order has expired' do
      it 'returns expired' do
        order = build(:trading_order,
                      start_time: (Time.current - 2.days).to_i.to_s,
                      end_time: (Time.current - 1.day).to_i.to_s)
        result = validator.validate(order)

        expect(result[:valid]).to be false
        expect(result[:reason]).to eq('expired')
      end
    end

    context 'when order is within valid time range' do
      it 'passes expiration check' do
        order = build(:trading_order,
                      start_time: (Time.current - 1.hour).to_i.to_s,
                      end_time: (Time.current + 7.days).to_i.to_s)
        result = validator.validate(order)

        expect(result[:valid]).to be true
      end
    end
  end

  describe '#validate - native token check' do
    it 'rejects orders with native tokens' do
      order = build(:trading_order, :list)
      order.consideration_item_type = Trading::Order::ItemType::NATIVE

      result = validator.validate(order)

      expect(result[:valid]).to be false
      expect(result[:reason]).to eq('native_token_unsupported')
    end

    it 'accepts orders with ERC20 consideration' do
      order = build(:trading_order, :list)
      order.consideration_item_type = Trading::Order::ItemType::ERC20

      result = validator.validate(order)
      expect(result[:valid]).to be true
    end
  end

  describe '#validate - balance checks' do
    context 'when balance is insufficient' do
      before do
        allow(Matching::OverMatch::Detection).to receive(:check_order_balance_and_approval)
          .and_return({ sufficient: false, reason: 'currency_insufficient' })
      end

      it 'returns balance_insufficient' do
        order = build(:trading_order)
        result = validator.validate(order)

        expect(result[:valid]).to be false
        expect(result[:reason]).to eq('balance_insufficient')
      end
    end

    context 'when NFT balance is insufficient' do
      before do
        allow(Matching::OverMatch::Detection).to receive(:check_order_balance_and_approval)
          .and_return({ sufficient: false, reason: 'token_insufficient' })
      end

      it 'returns token_insufficient' do
        order = build(:trading_order)
        result = validator.validate(order)

        expect(result[:valid]).to be false
        expect(result[:reason]).to eq('token_insufficient')
      end
    end

    context 'when ERC20 allowance is insufficient' do
      before do
        allow(Matching::OverMatch::Detection).to receive(:check_order_balance_and_approval)
          .and_return({ sufficient: false, reason: 'erc20_allowance_insufficient' })
      end

      it 'returns balance_insufficient' do
        order = build(:trading_order)
        result = validator.validate(order)

        expect(result[:valid]).to be false
        expect(result[:reason]).to eq('balance_insufficient')
      end
    end
  end

  describe '#validate - signature checks' do
    context 'when signature is invalid' do
      before do
        allow(Seaport::SignatureService).to receive(:validate_signature_with_details)
          .and_return({
            valid: false,
            details: {
              recovered_signer: '0xwrong',
              message: 'signer mismatch'
            }
          })
      end

      it 'returns signature_invalid' do
        order = build(:trading_order, signature: '0xfakesig')
        result = validator.validate(order)

        expect(result[:valid]).to be false
        expect(result[:reason]).to eq('signature_invalid')
      end
    end

    context 'when signature validation raises exception' do
      before do
        allow(Seaport::SignatureService).to receive(:validate_signature_with_details)
          .and_raise(StandardError, 'crypto error')
      end

      it 'returns signature_invalid with error details' do
        order = build(:trading_order, signature: '0xsig')
        result = validator.validate(order)

        expect(result[:valid]).to be false
        expect(result[:reason]).to eq('signature_invalid')
        expect(result[:details][:error]).to eq('crypto error')
      end
    end

    context 'when signature is blank' do
      it 'passes validation (signature check skipped)' do
        order = build(:trading_order, signature: nil)
        result = validator.validate(order)
        expect(result[:valid]).to be true
      end
    end
  end

  describe '#validate - zone restriction checks' do
    context 'when zone validation fails' do
      before do
        allow_any_instance_of(Orders::ZoneValidationService).to receive(:validate)
          .and_return({ success: false, errors: ['token not in whitelist'] })
      end

      it 'returns zone_restriction_failed' do
        order = build(:trading_order, parameters: '{"offer":[],"consideration":[]}')
        result = validator.validate(order)

        expect(result[:valid]).to be false
        expect(result[:reason]).to eq('zone_restriction_failed')
      end
    end

    context 'when parameters are blank' do
      it 'passes zone check (build_order_params returns nil)' do
        order = build(:trading_order, parameters: nil)
        result = validator.validate(order)
        expect(result[:valid]).to be true
      end
    end
  end

  describe '#validate - exception handling' do
    it 'returns validation_error when unexpected exception occurs' do
      allow(validator).to receive(:check_expiration).and_raise(StandardError, 'boom')
      order = build(:trading_order)
      result = validator.validate(order)

      expect(result[:valid]).to be false
      expect(result[:reason]).to eq(:validation_error)
      expect(result[:details][:error]).to eq('boom')
    end
  end

  describe '#validate_batch' do
    it 'separates valid and invalid orders' do
      valid_order = build(:trading_order)
      expired_order = build(:trading_order,
                            start_time: (Time.current - 2.days).to_i.to_s,
                            end_time: (Time.current - 1.day).to_i.to_s)

      result = validator.validate_batch([valid_order, expired_order])

      expect(result[:valid_count]).to eq(1)
      expect(result[:invalid_count]).to eq(1)
      expect(result[:valid_orders]).to include(valid_order)
      expect(result[:invalid_orders].first[:order]).to eq(expired_order)
    end

    it 'handles empty array' do
      result = validator.validate_batch([])

      expect(result[:valid_count]).to eq(0)
      expect(result[:invalid_count]).to eq(0)
      expect(result[:valid_orders]).to be_empty
      expect(result[:invalid_orders]).to be_empty
    end

    it 'handles all valid orders' do
      orders = Array.new(3) { build(:trading_order) }
      result = validator.validate_batch(orders)

      expect(result[:valid_count]).to eq(3)
      expect(result[:invalid_count]).to eq(0)
    end

    it 'handles all invalid orders' do
      orders = Array.new(2) do
        build(:trading_order,
              start_time: (Time.current - 2.days).to_i.to_s,
              end_time: (Time.current - 1.day).to_i.to_s)
      end
      result = validator.validate_batch(orders)

      expect(result[:valid_count]).to eq(0)
      expect(result[:invalid_count]).to eq(2)
    end
  end
end
