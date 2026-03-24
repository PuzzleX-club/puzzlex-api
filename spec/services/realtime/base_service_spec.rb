# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Realtime::BaseService do
  let(:channel) { "test_channel" }
  let(:data) { { message: "test_data" } }
  
  before do
    allow(ActionCable.server).to receive(:broadcast)
    allow(Redis.current).to receive(:get).and_return("1")
  end
  
  describe '.broadcast' do
    context 'when channel has active subscriptions' do
      it 'broadcasts data successfully' do
        expect(ActionCable.server).to receive(:broadcast).with(
          channel,
          hash_including(
            channel: channel,
            data: data,
            timestamp: kind_of(Integer)
          )
        )
        
        result = described_class.broadcast(channel, data)
        expect(result).to be true
      end
    end
    
    context 'when channel has no active subscriptions' do
      before do
        allow(Redis.current).to receive(:get).and_return("0")
      end
      
      it 'does not broadcast' do
        expect(ActionCable.server).not_to receive(:broadcast)
        
        result = described_class.broadcast(channel, data)
        expect(result).to be false
      end
    end
    
    context 'when force option is true' do
      before do
        allow(Redis.current).to receive(:get).and_return("0")
      end
      
      it 'broadcasts even without active subscriptions' do
        expect(ActionCable.server).to receive(:broadcast)
        
        result = described_class.broadcast(channel, data, force: true)
        expect(result).to be true
      end
    end
    
    context 'when broadcasting fails' do
      before do
        allow(ActionCable.server).to receive(:broadcast).and_raise(StandardError.new("Connection failed"))
      end
      
      it 'handles error gracefully' do
        result = described_class.broadcast(channel, data)
        expect(result).to be false
      end
    end
  end
  
  describe '.batch_broadcast' do
    let(:broadcasts) do
      [
        { channel: "channel1", data: { msg: "data1" } },
        { channel: "channel2", data: { msg: "data2" } }
      ]
    end
    
    it 'broadcasts multiple messages' do
      expect(ActionCable.server).to receive(:broadcast).twice
      
      result = described_class.batch_broadcast(broadcasts)
      
      expect(result[:success]).to contain_exactly("channel1", "channel2")
      expect(result[:failed]).to be_empty
    end
    
    it 'tracks failed broadcasts' do
      allow(ActionCable.server).to receive(:broadcast).and_raise(StandardError.new("Failed"))
      
      result = described_class.batch_broadcast(broadcasts)
      
      expect(result[:success]).to be_empty
      expect(result[:failed]).to contain_exactly("channel1", "channel2")
    end
  end
  
  describe '.has_active_subscriptions?' do
    it 'returns true when subscriptions exist' do
      allow(Redis.current).to receive(:get).with("sub_count:#{channel}").and_return("5")
      
      result = described_class.has_active_subscriptions?(channel)
      expect(result).to be true
    end
    
    it 'returns false when no subscriptions' do
      allow(Redis.current).to receive(:get).with("sub_count:#{channel}").and_return("0")
      
      result = described_class.has_active_subscriptions?(channel)
      expect(result).to be false
    end
    
    it 'returns false when subscription count is nil' do
      allow(Redis.current).to receive(:get).with("sub_count:#{channel}").and_return(nil)
      
      result = described_class.has_active_subscriptions?(channel)
      expect(result).to be false
    end
  end
  
  describe '.active_channels' do
    let(:redis_keys) { ["sub_count:channel1", "sub_count:channel2", "sub_count:channel3"] }
    
    before do
      allow(Redis.current).to receive(:keys).with("sub_count:*").and_return(redis_keys)
      allow(Redis.current).to receive(:get).with("sub_count:channel1").and_return("5")
      allow(Redis.current).to receive(:get).with("sub_count:channel2").and_return("0")
      allow(Redis.current).to receive(:get).with("sub_count:channel3").and_return("3")
    end
    
    it 'returns only channels with active subscriptions' do
      result = described_class.active_channels
      
      expect(result).to contain_exactly("channel1", "channel3")
    end
    
    it 'supports pattern matching' do
      allow(Redis.current).to receive(:keys).with("sub_count:*@TICKER_*").and_return(["sub_count:123@TICKER_1"])
      allow(Redis.current).to receive(:get).with("sub_count:123@TICKER_1").and_return("2")
      
      result = described_class.active_channels("*@TICKER_*")
      
      expect(result).to contain_exactly("123@TICKER_1")
    end
  end
end