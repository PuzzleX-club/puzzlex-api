# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Strategies::KlineSchedulingStrategy do
  let(:strategy) { described_class.new }
  let(:current_time) { Time.parse('2023-01-01 12:00:00') }
  
  before do
    allow(Time).to receive(:now).and_return(current_time)
    allow(Redis.current).to receive(:keys).and_return([])
    allow(Redis.current).to receive(:get).and_return(nil)
    allow(Redis.current).to receive(:set)
  end
  
  describe '#topic_types' do
    it 'returns KLINE' do
      expect(strategy.topic_types).to eq(['KLINE'])
    end
  end
  
  describe '#get_pending_tasks' do
    let(:active_topics) { ['123@KLINE_60', '456@KLINE_300'] }
    
    before do
      allow(strategy).to receive(:get_active_subscriptions).and_return(active_topics)
      allow(Realtime::TopicParser).to receive(:parse_topic).with('123@KLINE_60').and_return({
        topic_type: 'KLINE',
        market_id: 123,
        interval: 60
      })
      allow(Realtime::TopicParser).to receive(:parse_topic).with('456@KLINE_300').and_return({
        topic_type: 'KLINE',
        market_id: 456,
        interval: 300
      })
    end
    
    context 'when topics need realtime broadcast' do
      before do
        # Mock next_aligned_ts to be in the future
        allow(Redis.current).to receive(:get).with('next_aligned_ts:123@KLINE_60').and_return((current_time.to_i + 1800).to_s)
        allow(Redis.current).to receive(:get).with('next_aligned_ts:456@KLINE_300').and_return((current_time.to_i + 3600).to_s)
      end
      
      it 'creates realtime kline tasks' do
        tasks = strategy.get_pending_tasks
        
        expect(tasks).not_to be_empty
        realtime_tasks = tasks.select { |task| task[:params][:batch].any? { |item| item[2][:is_realtime] } }
        expect(realtime_tasks).not_to be_empty
      end
    end
    
    context 'when topics need aligned broadcast' do
      before do
        # Mock next_aligned_ts to be in the past (should trigger aligned broadcast)
        allow(Redis.current).to receive(:get).with('next_aligned_ts:123@KLINE_60').and_return((current_time.to_i - 100).to_s)
        allow(Redis.current).to receive(:get).with('next_aligned_ts:456@KLINE_300').and_return((current_time.to_i - 200).to_s)
      end
      
      it 'creates aligned kline tasks' do
        tasks = strategy.get_pending_tasks
        
        expect(tasks).not_to be_empty
        aligned_tasks = tasks.select { |task| task[:params][:batch].any? { |item| !item[2][:is_realtime] } }
        expect(aligned_tasks).not_to be_empty
      end
    end
    
    context 'when no topics need scheduling' do
      before do
        # Mock next_aligned_ts to be exactly now (no scheduling needed)
        allow(Redis.current).to receive(:get).with('next_aligned_ts:123@KLINE_60').and_return(current_time.to_i.to_s)
        allow(Redis.current).to receive(:get).with('next_aligned_ts:456@KLINE_300').and_return(current_time.to_i.to_s)
      end
      
      it 'returns empty tasks' do
        tasks = strategy.get_pending_tasks
        
        expect(tasks).to be_empty
      end
    end
    
    context 'when Realtime::TopicParser returns invalid data' do
      before do
        allow(Realtime::TopicParser).to receive(:parse_topic).and_return(nil)
      end
      
      it 'skips invalid topics' do
        tasks = strategy.get_pending_tasks
        
        expect(tasks).to be_empty
      end
    end
  end
end
