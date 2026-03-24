# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Matching::Fulfillment::GraphBuilder do
  let(:erc20) { '0x00000000000000000000000000000000000000aa' }
  let(:nft) { '0x00000000000000000000000000000000000000bb' }

  let(:orders_by_hash) do
    {
      'B1' => OpenStruct.new(
        order_hash: 'B1',
        parameters: {
          offerer: '0x0000000000000000000000000000000000000b01',
          conduitKey: '0x00',
          offer: [
            { itemType: 1, token: erc20 },
            { itemType: 1, token: erc20 },
            { itemType: 1, token: erc20 }
          ],
          consideration: [{ itemType: 3, token: nft, recipient: '0x0000000000000000000000000000000000000b01' }]
        },
        signature: '0x01'
      ),
      'B2' => OpenStruct.new(
        order_hash: 'B2',
        parameters: {
          offerer: '0x0000000000000000000000000000000000000b02',
          conduitKey: '0x00',
          offer: [
            { itemType: 1, token: erc20 },
            { itemType: 1, token: erc20 },
            { itemType: 1, token: erc20 }
          ],
          consideration: [{ itemType: 3, token: nft, recipient: '0x0000000000000000000000000000000000000b02' }]
        },
        signature: '0x02'
      ),
      'A1' => OpenStruct.new(
        order_hash: 'A1',
        parameters: {
          offer: [{ itemType: 3, token: nft }],
          consideration: [
            { itemType: 1, token: erc20 },
            { itemType: 1, token: erc20 },
            { itemType: 1, token: erc20 }
          ]
        },
        signature: '0x03'
      ),
      'A2' => OpenStruct.new(
        order_hash: 'A2',
        parameters: {
          offer: [{ itemType: 3, token: nft }],
          consideration: [
            { itemType: 1, token: erc20 },
            { itemType: 1, token: erc20 },
            { itemType: 1, token: erc20 }
          ]
        },
        signature: '0x04'
      )
    }
  end

  let(:match_orders) do
    [
      {
        'side' => 'Offer',
        'bid' => [62, 3, 'B1'],
        'ask' => {
          current_orders: ['A1', 'A2']
        },
        'ask_fills' => [
          { 'order_hash' => 'A1', 'filled_qty' => 2 },
          { 'order_hash' => 'A2', 'filled_qty' => 1 }
        ]
      },
      {
        'side' => 'Offer',
        'bid' => [62, 2, 'B2'],
        'ask' => {
          current_orders: ['A1']
        },
        'ask_fills' => [
          { 'order_hash' => 'A1', 'filled_qty' => 2 }
        ]
      }
    ]
  end

  it 'builds ask-aggregated fulfillments for mxn fills' do
    graph = described_class.new(match_orders: match_orders, orders_by_hash: orders_by_hash).build

    expect(graph[:orders_hash]).to match_array(%w[B1 A1 A2 B2])
    expect(graph[:fills].size).to eq(3)

    # A1 is split across two bids with different offerers:
    # payment fulfillments must be split per bid-side homogeneous group.
    ask_a1_index = graph[:order_index_map]['A1']
    bid_b1_index = graph[:order_index_map]['B1']
    bid_b2_index = graph[:order_index_map]['B2']

    payment_for_a1 = graph[:fulfillments].select do |f|
      f[:considerationComponents] == [{ orderIndex: ask_a1_index, itemIndex: 0 }] ||
        f[:considerationComponents] == [{ orderIndex: ask_a1_index, itemIndex: 1 }] ||
        f[:considerationComponents] == [{ orderIndex: ask_a1_index, itemIndex: 2 }]
    end
    expect(payment_for_a1.size).to eq(6)
    payment_for_a1.group_by { |f| f[:considerationComponents][0][:itemIndex] }.each_value do |item_group|
      expect(item_group.size).to eq(2)
      expect(item_group.map { |f| f[:offerComponents].size }).to all(eq(1))
      expect(item_group.map { |f| f[:offerComponents][0][:orderIndex] }).to match_array([bid_b1_index, bid_b2_index])
    end

    # NFT transfer from A1 should also split by bid-side recipient.
    nft_from_a1 = graph[:fulfillments].select do |f|
      f[:offerComponents] == [{ orderIndex: ask_a1_index, itemIndex: 0 }]
    end
    expect(nft_from_a1.size).to eq(2)
    expect(nft_from_a1.map { |f| f[:considerationComponents].size }).to all(eq(1))
    expect(nft_from_a1.map { |f| f[:considerationComponents][0][:orderIndex] }).to match_array([bid_b1_index, bid_b2_index])
  end
end
