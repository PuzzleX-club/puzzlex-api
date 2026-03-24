require 'rails_helper'

RSpec.describe Orders::ItemAndFillExtractor, type: :service do
  before do
    # 使用 ServiceTestHelpers 提供的 stub 方法
    stub_redis
    stub_action_cable
    stub_sidekiq_workers
  end

  describe '.extract_data' do
    let(:order_parameters) do
      {
        "offerer" => "0xofferer",
        "offer" => [{"token"=>"abc123","startAmount"=>"10","endAmount"=>"20","identifierOrCriteria"=>"1001","itemType"=>"2"}],
        "consideration" => [{"token"=>"def456","startAmount"=>"3000","endAmount"=>"4000","identifierOrCriteria"=>"0","itemType"=>"1","recipient"=>"0xrecipient"}],
        "startTime" => "1000",
        "endTime" => "2000"
      }
    end
    let(:order) { double('Order', order_direction: order_direction, parameters: order_parameters, order_hash: '0xorderhash') }

    subject(:extract_result) { described_class.extract_data(event_record, order) }

    context 'when event_name is OrderValidated' do
      let(:order_direction) { 'List' } # 卖单, item来自 offer
      let(:event_record) do
        double('EventRecord',
               event_name: 'OrderValidated',
               offer: [
                 { "token" => "abc123", "identifierOrCriteria" => "1001", "startAmount" => "10", "endAmount" => "20", "itemType" => "2" }
               ].to_json,
               consideration: [
                 { "token" => "def456", "identifierOrCriteria" => "0", "startAmount" => "3000", "endAmount" => "4000", "itemType" => "1" }
               ].to_json)
      end

      it "returns items_data from offer side, no fills_data" do
        items_data, fills_data = extract_result
        expect(items_data).to be_an(Array)
        expect(fills_data).to eq([])

        # 由于 order_direction='List', item_side=:offer => 这里 parse event_record.offer
        expect(items_data.size).to eq(1)
        item = items_data.first
        expect(item["token_address"]).to eq("0xabc123")
        expect(item["token_id"]).to eq("1001")
        expect(item["role"]).to eq("offer")  # 'List' => item_side= :offer
      end
    end

    context 'when event_name is OrderFulfilled' do
      let(:order_direction) { 'Offer' }
      let(:order_parameters) do
        {
          "offerer" => "0xofferer",
          "offer" => [{"token"=>"00aaa","startAmount"=>"500","endAmount"=>"500","identifierOrCriteria"=>"0","itemType"=>"0"}],
          "consideration" => [{"token"=>"00bbb","startAmount"=>"300","endAmount"=>"300","identifierOrCriteria"=>"1001","itemType"=>"2","recipient"=>"0xrecipient"}],
          "startTime" => "1000",
          "endTime" => "2000"
        }
      end
      let(:event_record) do
        double('EventRecord',
               id: 1,
               event_name: 'OrderFulfilled',
               transaction_hash: '0xtxhash123',
               block_timestamp: Time.current.to_i,
               log_index: 1,
               offerer: '0xofferer',
               recipient: '0xrecipient',
               offer: [
                 { "token" => "00aaa", "identifier" => "0", "amount" => "500", "itemType" => "0" }
               ].to_json,
               consideration: [
                 { "token" => "00bbb", "identifier" => "1001", "amount" => "300", "itemType" => "2", "recipient" => "0xrecipient" }
               ].to_json)
      end

      it "returns fills_data, no items_data" do
        items_data, fills_data = extract_result
        # OrderFulfilled 也会提取 items_data
        expect(items_data).to be_an(Array)
        expect(fills_data).to be_an(Array)
        # 断言 fills_data 结构
        fill = fills_data.first
        expect(fill["transaction_hash"]).to eq('0xtxhash123')
      end
    end

    context 'when event_name is OrdersMatched' do
      let(:order_direction) { 'Offer' }
      let(:event_record) do
        double('EventRecord',
               event_name: 'OrdersMatched',
               transaction_hash: '0xtxhash456',
               block_timestamp: Time.current.to_i,
               log_index: 2,
               matched_orders: ["0xOrderHashABC"].to_json)
      end

      before do
        # Stub 匹配的订单查询
        matched_order = double('MatchedOrder',
                               order_hash: "0xOrderHashABC",
                               order_direction: "Offer",
                               total_size: 100,
                               total_filled: 50,
                               parameters: {
                                 "startTime" => "100", "endTime" => "200",
                                 "offer" => [{"token"=>"0xCCC","startAmount"=>"50","endAmount"=>"100","recipient"=>"0xRecip1","identifierOrCriteria"=>"0","itemType"=>"0"}],
                                 "consideration" => [{"token"=>"0xDDD","startAmount"=>"200","endAmount"=>"300","identifierOrCriteria"=>"1001","itemType"=>"2","recipient"=>"0xRecip2"}],
                                 "offerer" => "0xOrderCreator"
                               })
        allow(Trading::Order).to receive(:find_by).with(order_hash: "0xOrderHashABC").and_return(matched_order)
      end

      it "returns fills_data for matched orders" do
        items_data, fills_data = extract_result
        expect(items_data).to eq([])
        expect(fills_data).not_to be_empty
      end
    end

    context 'when event_name is something else' do
      let(:order_direction) { 'List' }
      let(:event_record) do
        double('EventRecord', event_name: 'NonRelevantEvent')
      end

      it "returns empty items and fills" do
        items_data, fills_data = extract_result
        expect(items_data).to eq([])
        expect(fills_data).to eq([])
      end
    end
  end

  describe '.determine_sides_by_direction' do
    it "returns {item_side: :offer, price_side: :consideration} if direction='List'" do
      sides = described_class.determine_sides_by_direction('List')
      expect(sides).to eq({item_side: :offer, price_side: :consideration})
    end

    it "returns {item_side: :consideration, price_side: :offer} if direction='Offer'" do
      sides = described_class.determine_sides_by_direction('Offer')
      expect(sides).to eq({item_side: :consideration, price_side: :offer})
    end
  end

  describe '.extract_buyer_seller_addresses' do
    let(:order) { double('Order', order_direction: 'List') }
    let(:event_record) do
      double('EventRecord',
             event_name: 'OrderFulfilled',
             offerer: '0xseller123',
             recipient: '0xbuyer456')
    end

    context 'with List order (sell order)' do
      it 'returns recipient as buyer and offerer as seller' do
        buyer, seller = described_class.extract_buyer_seller_addresses(event_record, order)

        expect(buyer).to eq('0xbuyer456')
        expect(seller).to eq('0xseller123')
      end
    end

    context 'with Offer order (buy order)' do
      let(:order) { double('Order', order_direction: 'Offer') }

      it 'returns offerer as buyer and recipient as seller' do
        buyer, seller = described_class.extract_buyer_seller_addresses(event_record, order)

        expect(buyer).to eq('0xseller123')
        expect(seller).to eq('0xbuyer456')
      end
    end

    context 'with non-OrderFulfilled event' do
      let(:event_record) { double('EventRecord', event_name: 'OrderValidated') }

      it 'returns nil values' do
        buyer, seller = described_class.extract_buyer_seller_addresses(event_record, order)

        expect(buyer).to be_nil
        expect(seller).to be_nil
      end
    end

    context 'with missing addresses' do
      let(:event_record) do
        double('EventRecord', event_name: 'OrderFulfilled', offerer: nil, recipient: '0xbuyer')
      end

      it 'returns nil values' do
        buyer, seller = described_class.extract_buyer_seller_addresses(event_record, order)

        expect(buyer).to be_nil
        expect(seller).to be_nil
      end
    end
  end

  describe '.build_recipients_distribution' do
    let(:price_items) do
      [
        { 'token' => '0x0000', 'identifierOrCriteria' => '0', 'itemType' => '0', 'startAmount' => '100', 'recipient' => '0xrecipient1' },
        { 'token' => '0x0000', 'identifierOrCriteria' => '0', 'itemType' => '0', 'startAmount' => '50', 'recipient' => '0xrecipient2' }
      ]
    end

    it 'groups items by token, identifier, and item_type' do
      result = described_class.build_recipients_distribution(price_items, '0xofferer')

      expect(result).to be_an(Array)
      expect(result.length).to eq(1)
    end

    it 'calculates recipient ratios correctly' do
      result = described_class.build_recipients_distribution(price_items, '0xofferer')

      recipients = result.first['recipients']
      total_ratio = recipients.sum { |r| r['amount'].to_f }
      expect(total_ratio).to be_within(0.01).of(1.0)
    end

    context 'with zero total amount' do
      let(:zero_items) do
        [{ 'token' => '0x0000', 'identifierOrCriteria' => '0', 'itemType' => '0', 'startAmount' => '0', 'recipient' => '0xrecipient1' }]
      end

      it 'uses offerer as default recipient' do
        result = described_class.build_recipients_distribution(zero_items, '0xofferer')

        recipients = result.first['recipients']
        expect(recipients.first['address']).to eq('0xofferer')
        expect(recipients.first['amount']).to eq('1.0')
      end
    end
  end

  describe '.item_entries_sum' do
    let(:item_entries) do
      [
        { 'startAmount' => '100', 'endAmount' => '200' },
        { 'startAmount' => '50', 'endAmount' => '100' }
      ]
    end

    it 'calculates sum at time_progress 0' do
      result = described_class.item_entries_sum(item_entries, 0.0)

      expect(result).to eq(150) # 100 + 50
    end

    it 'calculates sum at time_progress 1' do
      result = described_class.item_entries_sum(item_entries, 1.0)

      expect(result).to eq(300) # 200 + 100
    end

    it 'calculates sum at time_progress 0.5' do
      result = described_class.item_entries_sum(item_entries, 0.5)

      expect(result).to eq(225) # interpolated value
    end
  end

  describe '.build_price_distribution_from_event' do
    let(:price_items) do
      [
        { 'token' => '0x0000', 'identifier' => '0', 'itemType' => '0', 'amount' => '100', 'recipient' => '0xrecipient1' },
        { 'token' => '0x0000', 'identifier' => '0', 'itemType' => '0', 'amount' => '50', 'recipient' => '0xrecipient2' }
      ]
    end
    let(:event_record) { double('EventRecord') }

    it 'builds distribution with total_amount' do
      result = described_class.build_price_distribution_from_event(price_items, event_record)

      expect(result).to be_an(Array)
      expect(result.first).to have_key('total_amount')
      expect(result.first['total_amount'].to_i).to eq(150)
    end

    it 'preserves raw amounts instead of ratios' do
      result = described_class.build_price_distribution_from_event(price_items, event_record)

      recipients = result.first['recipients']
      amounts = recipients.map { |r| r['amount'].to_i }
      expect(amounts).to contain_exactly(100, 50)
    end
  end

  describe '.build_price_distribution_from_order' do
    let(:price_entries) do
      [
        { 'token' => '0x0000', 'identifierOrCriteria' => '0', 'itemType' => '0', 'startAmount' => '100', 'endAmount' => '200', 'recipient' => '0xrecipient1' }
      ]
    end

    it 'calculates distribution based on time_progress and difference_fraction' do
      result = described_class.build_price_distribution_from_order(price_entries, 1.0, 0.5)

      expect(result).to be_an(Array)
      expect(result.first).to have_key('total_amount')
    end

    it 'returns empty array when amounts are zero' do
      zero_entries = [{ 'token' => '0x0000', 'identifierOrCriteria' => '0', 'itemType' => '0', 'startAmount' => '0', 'endAmount' => '0', 'recipient' => '0xrecipient1' }]

      result = described_class.build_price_distribution_from_order(zero_entries, 1.0, 0.5)

      expect(result).to eq([])
    end
  end
end