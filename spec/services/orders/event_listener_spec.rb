require 'rails_helper'

RSpec.describe Orders::EventListener do
  let(:service_class) { described_class }

  # Shared helper: stub Seaport::ContractService instance methods
  let(:mock_contract_service) { instance_double(Seaport::ContractService) }

  before do
    allow(Seaport::ContractService).to receive(:new).and_return(mock_contract_service)
    allow(mock_contract_service).to receive(:latest_block_number).and_return(nil)
    allow(mock_contract_service).to receive(:get_event_logs).and_return([])
  end

  describe '.listen_to_events' do
    context 'when latest_block is nil' do
      before do
        allow(service_class).to receive(:latest_block_number).and_return(nil)
      end

      it 'logs error and returns early' do
        expect(Rails.logger).to receive(:error).with(/无法获取最新区块号/)

        result = service_class.listen_to_events
        expect(result).to be_nil
      end
    end

    context 'when latest_block is available' do
      let(:latest_block) { 1000 }

      before do
        allow(service_class).to receive(:latest_block_number).and_return(latest_block)
        allow(service_class).to receive(:events_to_watch).and_return([
          { name: 'OrderValidated', model: Trading::OrderEvent }
        ])
      end

      it 'processes events and updates checkpoints' do
        expect(service_class).to receive(:resolve_from_block).with('OrderValidated').and_return(950)
        expect(service_class).to receive(:process_event_type).with(
          { name: 'OrderValidated', model: Trading::OrderEvent },
          from_block: 950, to_block: latest_block
        ).and_return(5)
        expect(service_class).to receive(:update_checkpoint).with('OrderValidated', latest_block)
        expect(service_class).to receive(:update_checkpoint).with('global', latest_block)
        # Implementation logs "EventListener: 最新区块 ..." then the total
        allow(Rails.logger).to receive(:info)
        expect(Rails.logger).to receive(:info).with(/本轮处理完成：共 5 个事件/)

        service_class.listen_to_events
      end

      context 'when event processing fails' do
        let(:error) { StandardError.new('Test error') }

        before do
          allow(service_class).to receive(:resolve_from_block).and_return(950)
          allow(service_class).to receive(:process_event_type).and_raise(error)
          allow(service_class).to receive(:record_retry_range)
        end

        it 'handles error gracefully and logs message' do
          expect(Rails.logger).to receive(:error).with(/处理 OrderValidated 失败/)
          expect(service_class).to receive(:record_retry_range).with('OrderValidated', 950, latest_block, error)

          service_class.listen_to_events
        end
      end

      context 'when from_block > latest_block' do
        before do
          allow(service_class).to receive(:resolve_from_block).and_return(1001)
        end

        it 'skips event and logs warning' do
          expect(Rails.logger).to receive(:warn).with(/起始区块.*高于最新区块/)

          service_class.listen_to_events
        end
      end

      context 'when no events processed' do
        before do
          allow(service_class).to receive(:resolve_from_block).and_return(950)
          allow(service_class).to receive(:process_event_type).and_return(0)
        end

        it 'logs completion with no events' do
          allow(Rails.logger).to receive(:info)
          expect(Rails.logger).to receive(:debug).with(/无新事件/)

          service_class.listen_to_events
        end
      end
    end
  end

  describe '.events_to_watch' do
    it 'returns correct events configuration' do
      events = service_class.events_to_watch

      expect(events).to be_an(Array)
      expect(events.length).to eq(5)

      event_names = events.map { |e| e[:name] }
      expect(event_names).to include('CounterIncremented')
      expect(event_names).to include('OrderValidated')
      expect(event_names).to include('OrderFulfilled')
      expect(event_names).to include('OrderCancelled')
      expect(event_names).to include('OrdersMatched')

      # Check model classes
      counter_event = events.find { |e| e[:name] == 'CounterIncremented' }
      expect(counter_event[:model]).to eq(Trading::CounterEvent)

      order_events = events.select { |e| e[:name] != 'CounterIncremented' }
      order_events.each { |e| expect(e[:model]).to eq(Trading::OrderEvent) }
    end
  end

  describe '.process_event_type' do
    let(:event) { { name: 'OrderValidated', model: Trading::OrderEvent } }
    let(:from_block) { 900 }
    let(:to_block) { 1000 }

    before do
      allow(service_class).to receive(:fetch_events).and_return([])
    end

    it 'processes events in batches' do
      # fetch_events returns hashes (decoded event logs)
      event_logs = [
        { transaction_hash: '0x1', block_number: 950 },
        { transaction_hash: '0x2', block_number: 951 }
      ]

      allow(service_class).to receive(:fetch_events).and_return(event_logs)
      allow(service_class).to receive(:process_event)

      expect(service_class).to receive(:process_event).twice
      expect(Rails.logger).to receive(:info).with(/发现 2 个 OrderValidated 事件/)

      result = service_class.process_event_type(event, from_block: from_block, to_block: to_block)
      expect(result).to eq(2)
    end

    context 'with CounterIncremented event' do
      let(:counter_event) { { name: 'CounterIncremented', model: Trading::CounterEvent } }
      let(:counter_log) { { transaction_hash: '0x1', block_number: 950 } }

      before do
        allow(service_class).to receive(:fetch_events).and_return([counter_log])
        allow(service_class).to receive(:process_event)
      end

      it 'processes CounterIncremented events' do
        expect(Rails.logger).to receive(:info).with(/发现 1 个 CounterIncremented 事件/)
        expect(service_class).to receive(:process_event).once

        result = service_class.process_event_type(counter_event, from_block: from_block, to_block: to_block)
        expect(result).to eq(1)
      end
    end
  end

  describe '.latest_block_number' do
    context 'when Seaport::ContractService is available' do
      let(:block_number) { 12345 }

      before do
        allow(mock_contract_service).to receive(:latest_block_number).and_return(block_number)
      end

      it 'returns block number from ContractService' do
        result = service_class.latest_block_number
        expect(result).to eq(block_number)
      end
    end

    context 'when ContractService fails' do
      before do
        allow(mock_contract_service).to receive(:latest_block_number).and_raise(StandardError.new('RPC Error'))
      end

      it 'raises the error (no internal rescue)' do
        expect { service_class.latest_block_number }.to raise_error(StandardError, 'RPC Error')
      end
    end
  end

  describe '.resolve_from_block' do
    let(:genesis_block) { Rails.application.config.x.blockchain.event_listener_genesis_block.to_i }

    before do
      allow(Onchain::EventListenerStatus).to receive(:update_status)
    end

    it 'returns genesis block when no checkpoint exists' do
      allow(Onchain::EventListenerStatus).to receive(:last_block).and_return(nil)

      result = service_class.resolve_from_block('CounterIncremented')
      expect(result).to eq(genesis_block)
    end

    it 'returns checkpoint for known event types' do
      allow(Onchain::EventListenerStatus).to receive(:last_block)
        .with(event_type: 'OrderValidated').and_return(950)
      allow(Onchain::EventListenerStatus).to receive(:last_block)
        .with(event_type: 'OrderFulfilled').and_return(900)

      expect(service_class.resolve_from_block('OrderValidated')).to eq(950)
      expect(service_class.resolve_from_block('OrderFulfilled')).to eq(900)
    end

    it 'returns genesis block when checkpoint is earliest' do
      allow(Onchain::EventListenerStatus).to receive(:last_block).and_return('earliest')

      result = service_class.resolve_from_block('UnknownEvent')
      expect(result).to eq(genesis_block)
    end
  end

  describe '.update_checkpoint' do
    let(:block_number) { 1000 }

    it 'updates checkpoint for specific event via EventListenerStatus' do
      expect(Onchain::EventListenerStatus).to receive(:update_status)
        .with('OrderValidated', block_number, event_type: 'OrderValidated')

      service_class.update_checkpoint('OrderValidated', block_number)
    end

    it 'updates global checkpoint via EventListenerStatus' do
      expect(Onchain::EventListenerStatus).to receive(:update_status)
        .with('global', block_number, event_type: 'global')

      service_class.update_checkpoint('global', block_number)
    end
  end

  describe '.record_retry_range' do
    let(:from_block) { 900 }
    let(:to_block) { 1000 }
    let(:error) { StandardError.new('Test error') }

    it 'records retry information to EventRetryRange' do
      mock_range = instance_double(Onchain::EventRetryRange, attempts: 0, next_retry_at: nil)
      allow(mock_range).to receive(:attempts=)
      allow(mock_range).to receive(:last_error=)
      allow(mock_range).to receive(:next_retry_at=)
      allow(mock_range).to receive(:save!).and_return(true)

      expect(Onchain::EventRetryRange).to receive(:find_or_initialize_by).with(
        event_type: 'OrderValidated',
        from_block: from_block,
        to_block: to_block
      ).and_return(mock_range)

      expect(mock_range).to receive(:save!)

      service_class.record_retry_range('OrderValidated', from_block, to_block, error)
    end
  end

  describe '.process_event' do
    context 'with OrderValidated event' do
      let(:event_hash) do
        {
          event_name: 'OrderValidated',
          model: Trading::OrderEvent,
          orderHash: '0x1234567890abcdef',
          orderParameters: { offerer: '0xabc', zone: '0xdef', offer: [], consideration: [] },
          transaction_hash: '0xabcdef1234567890',
          log_index: 0,
          block_number: 1000,
          block_timestamp: 1_700_000_000
        }
      end

      it 'creates event record and dispatches job' do
        allow(Trading::OrderEvent).to receive(:exists?).and_return(false)

        mock_record = instance_double(Trading::OrderEvent,
          id: 1, order_hash: '0x1234567890abcdef', event_name: 'OrderValidated')
        expect(Trading::OrderEvent).to receive(:create!).and_return(mock_record)

        allow(service_class).to receive(:process_event_synchronously)
        allow(Jobs::Orders::OrderEventHandlerJob).to receive(:perform_async)

        service_class.process_event(event_hash)
      end
    end

    context 'with OrderFulfilled event' do
      let(:event_hash) do
        {
          event_name: 'OrderFulfilled',
          model: Trading::OrderEvent,
          orderHash: '0x1234567890abcdef',
          offerer: '0xabc',
          zone: '0xdef',
          recipient: '0x123',
          offer: [],
          consideration: [],
          transaction_hash: '0xabcdef1234567890',
          log_index: 0,
          block_number: 1000,
          block_timestamp: 1_700_000_000
        }
      end

      it 'creates event record and dispatches job' do
        allow(Trading::OrderEvent).to receive(:exists?).and_return(false)

        mock_record = instance_double(Trading::OrderEvent,
          id: 2, order_hash: '0x1234567890abcdef', event_name: 'OrderFulfilled')
        expect(Trading::OrderEvent).to receive(:create!).and_return(mock_record)

        allow(service_class).to receive(:process_event_synchronously)
        allow(Jobs::Orders::OrderEventHandlerJob).to receive(:perform_async)

        service_class.process_event(event_hash)
      end
    end
  end

  describe '.fetch_events' do
    let(:from_block) { 950 }
    let(:to_block) { 1000 }

    context 'when fetching CounterIncremented events' do
      it 'delegates to Seaport::ContractService#get_event_logs' do
        expect(mock_contract_service).to receive(:get_event_logs).with(
          event_name: 'CounterIncremented',
          from_block: from_block,
          to_block: to_block
        ).and_return([])

        result = service_class.fetch_events(
          event_name: 'CounterIncremented',
          from_block: from_block,
          to_block: to_block
        )

        expect(result).to be_an(Array)
      end
    end

    context 'when fetching Order events' do
      it 'delegates to Seaport::ContractService#get_event_logs' do
        expect(mock_contract_service).to receive(:get_event_logs).with(
          event_name: 'OrderValidated',
          from_block: from_block,
          to_block: to_block
        ).and_return([])

        result = service_class.fetch_events(
          event_name: 'OrderValidated',
          from_block: from_block,
          to_block: to_block
        )

        expect(result).to be_an(Array)
      end
    end
  end

  describe '.assert_log_array!' do
    it 'does not raise when logs is an array' do
      expect {
        service_class.assert_log_array!(['log1', 'log2'], 'TestEvent')
      }.not_to raise_error
    end

    it 'raises error when logs is nil' do
      expect {
        service_class.assert_log_array!(nil, 'TestEvent')
      }.to raise_error(RuntimeError, /Unexpected TestEvent log payload/)
    end

    it 'raises error when logs is not an array' do
      expect {
        service_class.assert_log_array!('not_an_array', 'TestEvent')
      }.to raise_error(RuntimeError, /Unexpected TestEvent log payload/)
    end
  end

  describe 'Constants' do
    it 'defines required constants' do
      expect(described_class::BLOCK_BATCH_SIZE).to eq(90)
      expect(described_class::EVENTS_TO_WATCH).to be_a(Array)
      expect(described_class::GENESIS_BLOCK).to be_present
    end

    it 'EVENTS_TO_WATCH contains expected events' do
      event_names = described_class::EVENTS_TO_WATCH.map { |e| e[:name] }
      expect(event_names).to include('CounterIncremented')
      expect(event_names).to include('OrderValidated')
      expect(event_names).to include('OrderFulfilled')
      expect(event_names).to include('OrderCancelled')
      expect(event_names).to include('OrdersMatched')
    end
  end

  describe 'Integration scenario' do
    it 'handles complete event processing cycle' do
      latest_block = 1000
      allow(service_class).to receive(:latest_block_number).and_return(latest_block)

      events_to_watch = service_class.events_to_watch
      allow(service_class).to receive(:events_to_watch).and_return(events_to_watch)
      allow(service_class).to receive(:resolve_from_block).and_return(950)

      events_to_watch.each do |event|
        allow(service_class).to receive(:process_event_type).with(
          event, from_block: 950, to_block: latest_block
        ).and_return(2)
        allow(service_class).to receive(:update_checkpoint).with(event[:name], latest_block)
      end
      allow(service_class).to receive(:update_checkpoint).with('global', latest_block)

      # Implementation logs "EventListener: 最新区块 1000" then total (5*2=10)
      allow(Rails.logger).to receive(:info)
      expect(Rails.logger).to receive(:info).with(/本轮处理完成：共 10 个事件/)

      service_class.listen_to_events
    end
  end
end
