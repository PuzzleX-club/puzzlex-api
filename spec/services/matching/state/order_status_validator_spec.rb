require 'rails_helper'

RSpec.describe Matching::State::OrderStatusValidator, type: :service do
  let(:validator) { Matching::State::OrderStatusValidator.new }
  let(:market_id) { "test_market_validation" }

  before do
    # 使用 ServiceTestHelpers 提供的 stub 方法
    stub_redis
    stub_action_cable
    stub_sidekiq_workers
  end

  describe '#filter_valid_orders_for_matching' do
    let!(:valid_bid_order) do
      create(:trading_order, 
        market_id: market_id,
        order_direction: 'Offer',
        onchain_status: 'validated',
        offchain_status: 'active',
        offerer: '0x1234567890123456789012345678901234567890',
        order_hash: '0x1111111111111111111111111111111111111111111111111111111111111111',
        end_time: Rails.application.config.x.blockchain.seaport_max_uint256  # 永不过期
      )
    end

    let!(:valid_ask_order) do
      create(:trading_order,
        market_id: market_id, 
        order_direction: 'List',
        onchain_status: 'validated',
        offchain_status: 'active',
        offerer: '0x2345678901234567890123456789012345678901',
        order_hash: '0x2222222222222222222222222222222222222222222222222222222222222222',
        end_time: Rails.application.config.x.blockchain.seaport_max_uint256  # 永不过期
      )
    end

    let!(:invalid_status_order) do
      create(:trading_order,
        market_id: market_id,
        order_direction: 'Offer', 
        onchain_status: 'cancelled',
        offchain_status: 'active',
        order_hash: '0x3333333333333333333333333333333333333333333333333333333333333333',
        end_time: Rails.application.config.x.blockchain.seaport_max_uint256
      )
    end

    let!(:over_matched_order) do
      create(:trading_order,
        market_id: market_id,
        order_direction: 'List',
        onchain_status: 'validated', 
        offchain_status: 'over_matched',
        order_hash: '0x4444444444444444444444444444444444444444444444444444444444444444',
        end_time: Rails.application.config.x.blockchain.seaport_max_uint256
      )
    end

    let(:bids) do
      [
        [100.0, 5, valid_bid_order.order_hash, valid_bid_order.consideration_identifier, valid_bid_order.created_at.to_i],
        [99.0, 3, invalid_status_order.order_hash, invalid_status_order.consideration_identifier, invalid_status_order.created_at.to_i]
      ]
    end

    let(:asks) do
      [
        [101.0, 4, valid_ask_order.order_hash, valid_ask_order.offer_identifier, valid_ask_order.created_at.to_i],
        [102.0, 2, over_matched_order.order_hash, over_matched_order.offer_identifier, over_matched_order.created_at.to_i]
      ]
    end

    before do
      # Mock余额验证方法，假设余额充足
      allow(validator).to receive(:sufficient_currency_balance?).and_return(true)
      allow(validator).to receive(:sufficient_token_balance?).and_return(true)
      # Mock Matching::OverMatch::Detection 的方法
      allow(Matching::OverMatch::Detection).to receive(:get_order_currency_address).and_return('0x123')
      allow(Matching::OverMatch::Detection).to receive(:calculate_order_currency_amount).and_return(100)
      allow(Matching::OverMatch::Detection).to receive(:get_player_currency_balance).and_return(1000)
      allow(Matching::OverMatch::Detection).to receive(:get_order_token_id).and_return('123')
      allow(Matching::OverMatch::Detection).to receive(:calculate_order_token_amount).and_return(1)
      allow(Matching::OverMatch::Detection).to receive(:get_player_token_balance).and_return(10)
    end

    it '应该过滤出有效的订单' do
      result = validator.filter_valid_orders_for_matching(bids, asks)

      expect(result[:bids].size).to eq(1)
      expect(result[:asks].size).to eq(1)
      expect(result[:bids][0][2]).to eq(valid_bid_order.order_hash)
      expect(result[:asks][0][2]).to eq(valid_ask_order.order_hash)
    end

    it '应该记录过滤的订单数量' do
      result = validator.filter_valid_orders_for_matching(bids, asks)

      expect(result[:filtered_count][:bids]).to eq(1)
      expect(result[:filtered_count][:asks]).to eq(1)
    end

    context '当订单状态无效时' do
      it '应该过滤掉cancelled状态的订单' do
        result = validator.filter_valid_orders_for_matching(bids, [])

        valid_bid = result[:bids].find { |bid| bid[2] == valid_bid_order.order_hash }
        invalid_bid = result[:bids].find { |bid| bid[2] == invalid_status_order.order_hash }

        expect(valid_bid).to be_present
        expect(invalid_bid).to be_nil
      end

      it '应该过滤掉over_matched状态的订单' do
        result = validator.filter_valid_orders_for_matching([], asks)

        valid_ask = result[:asks].find { |ask| ask[2] == valid_ask_order.order_hash }
        invalid_ask = result[:asks].find { |ask| ask[2] == over_matched_order.order_hash }

        expect(valid_ask).to be_present
        expect(invalid_ask).to be_nil
      end
    end

    context '当余额不足时' do
      before do
        allow(validator).to receive(:sufficient_currency_balance?).and_return(false)
        allow(validator).to receive(:mark_order_over_matched)
      end

      it '应该标记买单为超匹配并过滤掉' do
        result = validator.filter_valid_orders_for_matching(bids, [])

        expect(result[:bids]).to be_empty
        expect(validator).to have_received(:mark_order_over_matched)
          .with(valid_bid_order, 'currency_insufficient')
      end
    end

    context '当订单 offchain_status 不为 active 时' do
      it '应该过滤掉 matching 状态的订单' do
        valid_bid_order.update!(offchain_status: 'matching')

        result = validator.filter_valid_orders_for_matching(bids, asks)

        expect(result[:bids]).to be_empty
        expect(result[:asks].size).to eq(1)
      end
    end

    context '当订单 offchain_status 为 active 时' do
      it '不依赖 Redis 中间态进行候选过滤' do
        # 候选过滤仅依赖订单状态与余额，不读取 Redis order_matching 中间态
        expect(Redis.current).not_to receive(:hgetall)

        result = validator.filter_valid_orders_for_matching(bids, asks)

        expect(result[:bids].size).to eq(1)
        expect(result[:bids][0][2]).to eq(valid_bid_order.order_hash)
      end
    end
  end

  describe '#update_orders_after_matching' do
    let!(:bid_order) do
      create(:trading_order,
        market_id: market_id,
        order_direction: 'Offer',
        offchain_status: 'active',
        order_hash: '0x5555555555555555555555555555555555555555555555555555555555555555',
        end_time: Rails.application.config.x.blockchain.seaport_max_uint256
      )
    end

    let!(:ask_order1) do
      create(:trading_order,
        market_id: market_id,
        order_direction: 'List', 
        offchain_status: 'active',
        order_hash: '0x6666666666666666666666666666666666666666666666666666666666666666',
        end_time: Rails.application.config.x.blockchain.seaport_max_uint256
      )
    end

    let!(:ask_order2) do
      create(:trading_order,
        market_id: market_id,
        order_direction: 'List',
        offchain_status: 'active',
        order_hash: '0x7777777777777777777777777777777777777777777777777777777777777777',
        end_time: Rails.application.config.x.blockchain.seaport_max_uint256
      )
    end

    let(:matched_orders) do
      [{
        'side' => 'Offer',
        'bid' => [100.0, 5, bid_order.order_hash],
        'ask' => { current_orders: [ask_order1.order_hash, ask_order2.order_hash] }
      }]
    end

    it '应该将所有匹配的订单状态更新为matching' do
      validator.update_orders_after_matching(matched_orders)

      bid_order.reload
      ask_order1.reload
      ask_order2.reload

      expect(bid_order.offchain_status).to eq('matching')
      expect(ask_order1.offchain_status).to eq('matching')
      expect(ask_order2.offchain_status).to eq('matching')
    end

    it '应该记录状态更新的原因' do
      validator.update_orders_after_matching(matched_orders)

      bid_order.reload
      expect(bid_order.offchain_status_reason).to eq('order_matched_processing')
    end

    it '应该更新状态更新时间' do
      freeze_time = Time.current
      allow(Time).to receive(:current).and_return(freeze_time)

      validator.update_orders_after_matching(matched_orders)

      bid_order.reload
      expect(bid_order.offchain_status_updated_at).to be_within(1.second).of(freeze_time)
    end
  end

  describe '#restore_orders_after_failed_matching' do
    let!(:order1) do
      create(:trading_order,
        market_id: market_id,
        offchain_status: 'matching',
        order_hash: '0x8888888888888888888888888888888888888888888888888888888888888888',
        end_time: Rails.application.config.x.blockchain.seaport_max_uint256
      )
    end

    let!(:order2) do
      create(:trading_order,
        market_id: market_id,
        offchain_status: 'matching',
        order_hash: '0x9999999999999999999999999999999999999999999999999999999999999999',
        end_time: Rails.application.config.x.blockchain.seaport_max_uint256
      )
    end

    let(:order_hashes) { [order1.order_hash, order2.order_hash] }

    it '应该将订单状态恢复为active' do
      validator.restore_orders_after_failed_matching(order_hashes)

      order1.reload
      order2.reload

      expect(order1.offchain_status).to eq('active')
      expect(order2.offchain_status).to eq('active')
    end

    it '应该记录恢复的原因' do
      validator.restore_orders_after_failed_matching(order_hashes)

      order1.reload
      expect(order1.offchain_status_reason).to eq('matching_failed_restored')
    end
  end

  describe 'private methods' do
    describe '#valid_basic_status?' do
      it '应该接受validated状态的active订单' do
        order = create(:trading_order, 
          onchain_status: 'validated', 
          offchain_status: 'active',
          end_time: Rails.application.config.x.blockchain.seaport_max_uint256
        )
        expect(validator.send(:valid_basic_status?, order)).to be true
      end

      it '应该接受partially_filled状态的active订单' do
        order = create(:trading_order, 
          onchain_status: 'partially_filled', 
          offchain_status: 'active',
          end_time: Rails.application.config.x.blockchain.seaport_max_uint256
        )
        expect(validator.send(:valid_basic_status?, order)).to be true
      end

      it '应该拒绝cancelled状态的订单' do
        order = create(:trading_order, 
          onchain_status: 'cancelled', 
          offchain_status: 'active',
          end_time: Rails.application.config.x.blockchain.seaport_max_uint256
        )
        expect(validator.send(:valid_basic_status?, order)).to be false
      end

      it '应该拒绝over_matched状态的订单' do
        order = create(:trading_order, 
          onchain_status: 'validated', 
          offchain_status: 'over_matched',
          end_time: Rails.application.config.x.blockchain.seaport_max_uint256
        )
        expect(validator.send(:valid_basic_status?, order)).to be false
      end

      context '当订单过期时' do
        it '应该拒绝已过期的订单' do
          expired_time = (Time.current - 1.hour).to_i
          order = create(:trading_order, 
            onchain_status: 'validated', 
            offchain_status: 'active',
            end_time: expired_time
          )

          allow(validator).to receive(:mark_order_expired)
          
          result = validator.send(:valid_basic_status?, order)
          
          expect(result).to be false
          expect(validator).to have_received(:mark_order_expired).with(order)
        end

        it '应该接受未过期的订单' do
          future_time = (Time.current + 1.hour).to_i
          order = create(:trading_order,
            onchain_status: 'validated',
            offchain_status: 'active', 
            end_time: future_time
          )

          expect(validator.send(:valid_basic_status?, order)).to be true
        end

        it '应该接受永不过期的订单' do
          order = create(:trading_order,
            onchain_status: 'validated',
            offchain_status: 'active',
            end_time: Rails.application.config.x.blockchain.seaport_max_uint256
          )

          expect(validator.send(:valid_basic_status?, order)).to be true
        end
      end
    end

    describe '#valid_basic_status? 作为唯一门禁' do
      it '唯一允许的 offchain_status 是 active' do
        active_order = create(:trading_order,
          onchain_status: 'validated',
          offchain_status: 'active',
          end_time: Rails.application.config.x.blockchain.seaport_max_uint256
        )
        matching_order = create(:trading_order,
          onchain_status: 'validated',
          offchain_status: 'matching',
          end_time: Rails.application.config.x.blockchain.seaport_max_uint256
        )

        expect(validator.send(:valid_basic_status?, active_order)).to be true
        expect(validator.send(:valid_basic_status?, matching_order)).to be false
      end
    end
  end

  describe '集成测试：完整撮合流程' do
    let!(:bid_order) do
      create(:trading_order,
        market_id: market_id,
        order_direction: 'Offer',
        onchain_status: 'validated',
        offchain_status: 'active',
        order_hash: '0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
        end_time: Rails.application.config.x.blockchain.seaport_max_uint256
      )
    end

    let!(:ask_order) do
      create(:trading_order,
        market_id: market_id,
        order_direction: 'List',
        onchain_status: 'validated', 
        offchain_status: 'active',
        order_hash: '0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
        end_time: Rails.application.config.x.blockchain.seaport_max_uint256
      )
    end

    before do
      # Mock余额验证为充足
      allow(validator).to receive(:sufficient_currency_balance?).and_return(true)
      allow(validator).to receive(:sufficient_token_balance?).and_return(true)
      # Mock Matching::OverMatch::Detection 的方法
      allow(Matching::OverMatch::Detection).to receive(:get_order_currency_address).and_return('0x123')
      allow(Matching::OverMatch::Detection).to receive(:calculate_order_currency_amount).and_return(100)
      allow(Matching::OverMatch::Detection).to receive(:get_player_currency_balance).and_return(1000)
      allow(Matching::OverMatch::Detection).to receive(:get_order_token_id).and_return('123')
      allow(Matching::OverMatch::Detection).to receive(:calculate_order_token_amount).and_return(1)
      allow(Matching::OverMatch::Detection).to receive(:get_player_token_balance).and_return(10)
    end

    it '应该完成完整的订单验证和状态更新流程' do
      # 1. 订单验证过滤
      bids = [[100.0, 5, bid_order.order_hash, bid_order.consideration_identifier, bid_order.created_at.to_i]]
      asks = [[101.0, 4, ask_order.order_hash, ask_order.offer_identifier, ask_order.created_at.to_i]]
      
      validation_result = validator.filter_valid_orders_for_matching(bids, asks)
      
      expect(validation_result[:bids].size).to eq(1)
      expect(validation_result[:asks].size).to eq(1)
      
      # 2. 模拟撮合成功，更新订单状态
      matched_orders = [{
        'side' => 'Offer',
        'bid' => [100.0, 5, bid_order.order_hash],
        'ask' => { current_orders: [ask_order.order_hash] }
      }]
      
      validator.update_orders_after_matching(matched_orders)
      
      bid_order.reload
      ask_order.reload
      
      expect(bid_order.offchain_status).to eq('matching')
      expect(ask_order.offchain_status).to eq('matching')
      
      # 3. 模拟撮合失败，恢复订单状态
      order_hashes = [bid_order.order_hash, ask_order.order_hash]
      validator.restore_orders_after_failed_matching(order_hashes)
      
      bid_order.reload
      ask_order.reload
      
      expect(bid_order.offchain_status).to eq('active')
      expect(ask_order.offchain_status).to eq('active')
      expect(bid_order.offchain_status_reason).to eq('matching_failed_restored')
    end
  end
end 
