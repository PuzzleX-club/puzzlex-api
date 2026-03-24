# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Matching::Fulfillment::PreflightValidator, type: :service do
  OrderStub = Struct.new(:order_hash, :total_size)

  let(:match_orders) do
    [
      {
        'side' => 'Offer',
        'bid' => [1000, 3, 'bid_hash'],
        'ask' => { current_orders: %w[ask_a ask_b] },
        'ask_fills' => [
          { 'order_hash' => 'ask_a', 'filled_qty' => 1 },
          { 'order_hash' => 'ask_b', 'filled_qty' => 2 }
        ],
        'bid_total' => 3,
        'bid_filled' => 3
      }
    ]
  end

  let(:orders_by_hash) do
    {
      'ask_a' => OrderStub.new('ask_a', 1),
      'ask_b' => OrderStub.new('ask_b', 2)
    }
  end

  let(:graph) do
    {
      fills: [
        { bid_hash: 'bid_hash', ask_hash: 'ask_a', filled_qty: 1 },
        { bid_hash: 'bid_hash', ask_hash: 'ask_b', filled_qty: 2 }
      ]
    }
  end

  it 'passes when strict full-fill invariants are satisfied' do
    expect(
      described_class.new(match_orders: match_orders, graph: graph, orders_by_hash: orders_by_hash).validate!
    ).to be true
  end

  it 'fails when ask is not fully filled' do
    broken_graph = {
      fills: [
        { bid_hash: 'bid_hash', ask_hash: 'ask_a', filled_qty: 1 },
        { bid_hash: 'bid_hash', ask_hash: 'ask_b', filled_qty: 1.5 }
      ]
    }

    expect do
      described_class.new(match_orders: match_orders, graph: broken_graph, orders_by_hash: orders_by_hash).validate!
    end.to raise_error(Matching::Fulfillment::PreflightValidator::ValidationError, /bid aggregated fill mismatch/)
  end

  it 'fails when fill edge is missing for an ask' do
    broken_graph = {
      fills: [
        { bid_hash: 'bid_hash', ask_hash: 'ask_a', filled_qty: 1 }
      ]
    }

    expect do
      described_class.new(match_orders: match_orders, graph: broken_graph, orders_by_hash: orders_by_hash).validate!
    end.to raise_error(Matching::Fulfillment::PreflightValidator::ValidationError, /missing ask fill edge/)
  end

  it 'fails when conservation is violated' do
    broken_graph = {
      fills: [
        { bid_hash: 'bid_hash', ask_hash: 'ask_a', filled_qty: 1 },
        { bid_hash: 'bid_hash', ask_hash: 'ask_b', filled_qty: 3 }
      ]
    }
    broken_orders = {
      'ask_a' => OrderStub.new('ask_a', 1),
      'ask_b' => OrderStub.new('ask_b', 3)
    }

    expect do
      described_class.new(match_orders: match_orders, graph: broken_graph, orders_by_hash: broken_orders).validate!
    end.to raise_error(Matching::Fulfillment::PreflightValidator::ValidationError, /bid aggregated fill mismatch/)
  end

  it 'fails when match ask_fills do not conserve bid quantity' do
    broken_match_orders = [
      {
        'side' => 'Offer',
        'bid' => [1000, 3, 'bid_hash'],
        'ask' => { current_orders: %w[ask_a ask_b] },
        'ask_fills' => [
          { 'order_hash' => 'ask_a', 'filled_qty' => 1 },
          { 'order_hash' => 'ask_b', 'filled_qty' => 1 }
        ],
        'bid_total' => 3,
        'bid_filled' => 3
      }
    ]

    expect do
      described_class.new(match_orders: broken_match_orders, graph: graph, orders_by_hash: orders_by_hash).validate!
    end.to raise_error(Matching::Fulfillment::PreflightValidator::ValidationError, /quantity conservation violated/)
  end

  it 'passes for mxn split fills when each bid/ask is fully filled globally' do
    mxn_match_orders = [
      {
        'side' => 'Offer',
        'bid' => [1000, 2, 'bid_1'],
        'ask' => { current_orders: %w[ask_x] },
        'ask_fills' => [{ 'order_hash' => 'ask_x', 'filled_qty' => 2 }],
        'bid_total' => 2,
        'bid_filled' => 2
      },
      {
        'side' => 'Offer',
        'bid' => [1000, 3, 'bid_2'],
        'ask' => { current_orders: %w[ask_x ask_y] },
        'ask_fills' => [
          { 'order_hash' => 'ask_x', 'filled_qty' => 2 },
          { 'order_hash' => 'ask_y', 'filled_qty' => 1 }
        ],
        'bid_total' => 3,
        'bid_filled' => 3
      },
      {
        'side' => 'Offer',
        'bid' => [1000, 5, 'bid_3'],
        'ask' => { current_orders: %w[ask_y] },
        'ask_fills' => [{ 'order_hash' => 'ask_y', 'filled_qty' => 5 }],
        'bid_total' => 5,
        'bid_filled' => 5
      }
    ]

    mxn_orders_by_hash = {
      'ask_x' => OrderStub.new('ask_x', 4),
      'ask_y' => OrderStub.new('ask_y', 6)
    }
    mxn_graph = {
      fills: [
        { bid_hash: 'bid_1', ask_hash: 'ask_x', filled_qty: 2 },
        { bid_hash: 'bid_2', ask_hash: 'ask_x', filled_qty: 2 },
        { bid_hash: 'bid_2', ask_hash: 'ask_y', filled_qty: 1 },
        { bid_hash: 'bid_3', ask_hash: 'ask_y', filled_qty: 5 }
      ]
    }

    expect(
      described_class.new(match_orders: mxn_match_orders, graph: mxn_graph, orders_by_hash: mxn_orders_by_hash).validate!
    ).to be true
  end

  it 'does not depend on total_size when ask_fills provides expected quantity' do
    zero_total_orders = {
      'ask_a' => OrderStub.new('ask_a', 0),
      'ask_b' => OrderStub.new('ask_b', 0)
    }

    expect(
      described_class.new(match_orders: match_orders, graph: graph, orders_by_hash: zero_total_orders).validate!
    ).to be true
  end

  it 'falls back to unfilled amount when ask_fills is missing' do
    fallback_match_orders = [
      {
        'side' => 'Offer',
        'bid' => [1000, 3, 'bid_hash'],
        'ask' => { current_orders: %w[ask_a ask_b] },
        'bid_total' => 3,
        'bid_filled' => 3
      }
    ]

    allow(Orders::OrderHelper).to receive(:calculate_unfill_amount_from_order) do |order|
      case order.order_hash
      when 'ask_a' then 1
      when 'ask_b' then 2
      else 0
      end
    end

    expect(
      described_class.new(match_orders: fallback_match_orders, graph: graph, orders_by_hash: orders_by_hash).validate!
    ).to be true
  end

  it 'fails fast when fulfillment component itemIndex is out of bounds' do
    broken_graph = {
      orders: [
        {
          parameters: {
            offer: [{ itemType: 1, token: '0x00000000000000000000000000000000000000aa' }],
            consideration: [{ itemType: 3, token: '0x00000000000000000000000000000000000000bb' }]
          }
        },
        {
          parameters: {
            offer: [{ itemType: 3, token: '0x00000000000000000000000000000000000000bb' }],
            consideration: [{ itemType: 1, token: '0x00000000000000000000000000000000000000aa' }]
          }
        }
      ],
      fulfillments: [
        {
          offerComponents: [{ orderIndex: 0, itemIndex: 2 }],
          considerationComponents: [{ orderIndex: 1, itemIndex: 0 }]
        }
      ],
      fills: graph[:fills]
    }

    expect do
      described_class.new(match_orders: match_orders, graph: broken_graph, orders_by_hash: orders_by_hash).validate!
    end.to raise_error(Matching::Fulfillment::PreflightValidator::ValidationError, /invalid fulfillment itemIndex/)
  end
end
