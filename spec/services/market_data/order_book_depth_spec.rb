require 'rails_helper'

RSpec.describe MarketData::OrderBookDepth, type: :service do
  let(:limit) { 5 }
  let(:market_id) { "30001" }

  describe "#call" do
    subject(:service_call) { described_class.new(market_id, limit, validate_criteria: false).call }

    before do
      # 清空数据库
      Trading::Order.delete_all

      # 创建几笔订单, 有的为"Offer"(买单), 有的"List"(卖单)
      # 并且是 "validated"/"partially_filled" 才算"未完成"
      # offchain_status 必须为 'active' 或 'matching'
      @buy_order1 = create(:trading_order,
                           market_id: market_id,
                           order_direction: "Offer",
                           onchain_status: "validated",
                           offchain_status: "active",
                           order_hash: "0xBuyOrderHash1"
      )
      @buy_order2 = create(:trading_order,
                           market_id: market_id,
                           order_direction: "Offer",
                           onchain_status: "partially_filled",
                           offchain_status: "active",
                           order_hash: "0xBuyOrderHash2"
      )
      @sell_order1 = create(:trading_order,
                            market_id: market_id,
                            order_direction: "List",
                            onchain_status: "validated",
                            offchain_status: "active",
                            order_hash: "0xSellOrderHash1"
      )

      # 也可以创建几个不匹配market_id或order_status=filled等测试不会出现在结果中的
      create(:trading_order,
             market_id: "OtherMarket",
             order_direction: "Offer",
             onchain_status: "validated",
             offchain_status: "active"
      )
      create(:trading_order,
             market_id: market_id,
             order_direction: "Offer",
             onchain_status: "filled",
             offchain_status: "active"
      )

      # Stub 各订单的"current_price"和"unfilled_qty"
      # 实现使用 _from_order 后缀方法
      allow(Orders::OrderHelper).to receive(:calculate_price_in_progress_from_order) do |order|
        case order.order_hash
        when "0xBuyOrderHash1"
          101.5
        when "0xBuyOrderHash2"
          100.0
        when "0xSellOrderHash1"
          102.3
        else
          99.0
        end
      end

      allow(Orders::OrderHelper).to receive(:calculate_unfill_amount_from_order) do |order|
        case order.order_hash
        when "0xBuyOrderHash1"
          10
        when "0xBuyOrderHash2"
          5
        when "0xSellOrderHash1"
          12
        else
          1
        end
      end
    end

    it "returns bids in descending order and asks in ascending order, ignoring other markets and filled orders" do
      result = service_call
      expect(result[:market_id]).to eq(market_id)
      expect(result[:levels]).to eq(limit)

      # bids => [[price_str, qty_str, order_hash, identifier, created_at_str], ...]
      # asks => same structure
      # Implementation converts price via: current_price.to_i.to_s (Wei string)
      bids = result[:bids]
      asks = result[:asks]

      # Check the buy orders (Offer)
      #   we have buy_order1 => price=101 (101.5.to_i), qty=10
      #            buy_order2 => price=100 (100.0.to_i), qty=5
      #   => sorted descending by Wei value => first=buy_order1(101), second=buy_order2(100)
      expect(bids.size).to eq(2)
      # Check price (as Wei int string), qty, and order_hash
      expect(bids.map { |b| [b[0], b[1], b[2]] }).to eq([
                           ["101", "10", "0xBuyOrderHash1"],
                           ["100", "5",  "0xBuyOrderHash2"]
                         ])

      # Check the sell orders (List)
      #   we have sell_order1 => price=102 (102.3.to_i), qty=12
      #   => sorted ascending => 只1笔
      expect(asks.size).to eq(1)
      expect(asks.map { |a| [a[0], a[1], a[2]] }).to eq([
                           ["102", "12", "0xSellOrderHash1"]
                         ])
    end

    context "when limit is smaller than number of orders" do
      let(:limit) { 1 }

      it "truncates the result to the given limit" do
        result = service_call
        # bids => only the top1 =>  [ [price_str, qty_str, "0xBuyOrderHash1", identifier, timestamp] ]
        expect(result[:bids].size).to eq(1)
        bid = result[:bids].first
        expect([bid[0], bid[1], bid[2]]).to eq(["101", "10", "0xBuyOrderHash1"])
      end
    end
  end
end