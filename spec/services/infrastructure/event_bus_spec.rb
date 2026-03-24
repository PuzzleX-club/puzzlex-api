# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Infrastructure::EventBus do
  before do
    Infrastructure::EventBus.clear_all_subscribers
  end

  after do
    Infrastructure::EventBus.clear_all_subscribers
  end

  describe '.subscribe and .publish' do
    it 'allows subscribing to events with a block' do
      result = nil
      
      Infrastructure::EventBus.subscribe('test.event') do |event|
        result = event.data[:message]
      end
      
      Infrastructure::EventBus.publish('test.event', { message: 'Hello World' })
      
      expect(result).to eq('Hello World')
    end
    
    it 'allows subscribing with an object and method' do
      listener = double('listener')
      expect(listener).to receive(:handle_event).with(instance_of(Infrastructure::EventBus::Event))
      
      Infrastructure::EventBus.subscribe('test.event', listener, method_name: :handle_event)
      Infrastructure::EventBus.publish('test.event', { data: 'test' })
    end
    
    it 'handles multiple subscribers for the same event' do
      results = []
      
      Infrastructure::EventBus.subscribe('test.event') { |event| results << 'first' }
      Infrastructure::EventBus.subscribe('test.event') { |event| results << 'second' }
      
      Infrastructure::EventBus.publish('test.event')
      
      expect(results).to contain_exactly('first', 'second')
    end
    
    it 'does not call subscribers for different events' do
      result = nil
      
      Infrastructure::EventBus.subscribe('other.event') { |event| result = 'called' }
      Infrastructure::EventBus.publish('test.event')
      
      expect(result).to be_nil
    end
  end
  
  describe '.unsubscribe' do
    it 'removes specific subscribers' do
      listener1 = double('listener1')
      listener2 = double('listener2')
      
      Infrastructure::EventBus.subscribe('test.event', listener1, method_name: :call)
      Infrastructure::EventBus.subscribe('test.event', listener2, method_name: :call)
      
      Infrastructure::EventBus.unsubscribe('test.event', listener1)
      
      expect(listener1).not_to receive(:call)
      expect(listener2).to receive(:call)
      
      Infrastructure::EventBus.publish('test.event')
    end
  end
  
  describe 'async processing' do
    it 'schedules async subscribers for background processing' do
      expect(Jobs::Indexer::EventProcessingWorker).to receive(:perform_async).with(
        hash_including('name' => 'test.event'),
        array_including(hash_including('listener_class' => 'RSpec::Mocks::Double'))
      )
      
      listener = double('listener')
      Infrastructure::EventBus.subscribe('test.event', listener, method_name: :call, async: true)
      
      Infrastructure::EventBus.publish('test.event', { data: 'async test' })
    end
    
    it 'processes sync and async subscribers separately' do
      sync_result = nil
      
      # 同步订阅者应该立即执行
      Infrastructure::EventBus.subscribe('test.event') { |event| sync_result = 'sync processed' }
      
      # 异步订阅者应该被调度
      async_listener = double('async_listener')
      Infrastructure::EventBus.subscribe('test.event', async_listener, method_name: :call, async: true)
      
      expect(Jobs::Indexer::EventProcessingWorker).to receive(:perform_async)
      
      Infrastructure::EventBus.publish('test.event')
      
      expect(sync_result).to eq('sync processed')
    end
  end
  
  describe '.stats' do
    it 'returns correct statistics' do
      Infrastructure::EventBus.subscribe('event1') { |e| }
      Infrastructure::EventBus.subscribe('event1') { |e| }
      Infrastructure::EventBus.subscribe('event2') { |e| }
      
      stats = Infrastructure::EventBus.stats
      
      expect(stats[:total_events]).to eq(2)
      expect(stats[:total_subscribers]).to eq(3)
      expect(stats[:events]['event1']).to eq(2)
      expect(stats[:events]['event2']).to eq(1)
    end
  end
  
  describe 'error handling' do
    it 'logs errors but continues processing other subscribers' do
      results = []
      
      Infrastructure::EventBus.subscribe('test.event') { |event| raise 'Error!' }
      Infrastructure::EventBus.subscribe('test.event') { |event| results << 'processed' }
      
      expect(Rails.logger).to receive(:error).at_least(:once)
      
      Infrastructure::EventBus.publish('test.event')
      
      expect(results).to include('processed')
    end
  end
  
  describe Infrastructure::EventBus::Event do
    it 'creates event with metadata' do
      event = Infrastructure::EventBus::Event.new(
        name: 'test.event',
        data: { key: 'value' },
        metadata: { source: 'test' }
      )
      
      expect(event.name).to eq('test.event')
      expect(event.data[:key]).to eq('value')
      expect(event.metadata[:source]).to eq('test')
    end
    
    it 'converts to hash correctly' do
      event = Infrastructure::EventBus::Event.new(
        name: 'test.event',
        data: { key: 'value' },
        metadata: { published_at: Time.current }
      )
      
      hash = event.to_h
      
      expect(hash[:name]).to eq('test.event')
      expect(hash[:data][:key]).to eq('value')
      expect(hash[:metadata][:published_at]).to be_present
    end
  end
end
