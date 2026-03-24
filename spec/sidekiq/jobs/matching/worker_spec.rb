# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Jobs::Matching::Worker, type: :job do
  include ServiceTestHelpers

  let(:redis) { stub_redis }
  let(:market_id) { '2800' }
  let(:sched) do
    config = ActiveSupport::OrderedOptions.new
    config.worker_timeout_sec   = 5
    config.lock_ttl_sec         = 10
    config.loop_budget_sec      = 3
    config.followup_delay_sec   = 1.0
    config.waiting_delay_sec    = 10
    config.dedup_ttl_sec        = 2
    config
  end

  before do
    stub_action_cable
    stub_sidekiq_workers
    allow(Sidekiq).to receive(:redis).and_yield(redis)
    allow(redis).to receive(:eval).and_return(1)
    allow(Rails.configuration.x).to receive(:match_scheduler).and_return(sched)
  end

  def build_matcher(matched_count:)
    double('MatchEngine',
      perform: { matched_count: matched_count, matched_orders: [], status: :completed },
      logger: double('Logger', respond_to?: false)
    )
  end

  describe '#perform' do
    context 'dedup key cleanup after lock acquired' do
      before { allow(redis).to receive(:set).and_return(true) }

      it 'deletes the follow-up dedup key after acquiring the lock' do
        matcher = build_matcher(matched_count: 0)
        allow(Matching::Engine).to receive(:new).and_return(matcher)

        expect(redis).to receive(:del).with("match_followup:#{market_id}")

        subject.perform(market_id, 'scheduled')
      end

      it 'does not delete dedup key when lock is not acquired' do
        allow(subject).to receive(:with_redis_lock).and_yield(false)

        expect(redis).not_to receive(:del).with("match_followup:#{market_id}")

        subject.perform(market_id, 'scheduled')
      end
    end

    context 'lock TTL safety guard' do
      it 'uses at least worker_timeout + 5 as lock TTL' do
        sched.lock_ttl_sec = 3 # intentionally too low
        sched.worker_timeout_sec = 5

        allow(redis).to receive(:set).and_return(true)
        matcher = build_matcher(matched_count: 0)
        allow(Matching::Engine).to receive(:new).and_return(matcher)

        # The lock should use max(3, 5+5) = 10
        expect(redis).to receive(:set).with("match_lock:#{market_id}", anything, nx: true, ex: 10).and_return(true)

        subject.perform(market_id, 'scheduled')
      end
    end

    context 'when lock is acquired' do
      before { allow(redis).to receive(:set).and_return(true) }

      it 'performs order matching' do
        matcher = build_matcher(matched_count: 0)
        allow(Matching::Engine).to receive(:new).and_return(matcher)

        expect(matcher).to receive(:perform)
        subject.perform(market_id, 'scheduled')
      end

      it 'handles successful matching without error' do
        matcher = build_matcher(matched_count: 1)
        allow(Matching::Engine).to receive(:new).and_return(matcher)

        expect { subject.perform(market_id, 'scheduled') }.not_to raise_error
      end
    end

    context 'continuous loop' do
      before { allow(redis).to receive(:set).and_return(true) }

      it 'runs multiple rounds when matches are found' do
        call_count = 0
        allow(Matching::Engine).to receive(:new) do
          call_count += 1
          if call_count <= 3
            build_matcher(matched_count: 2)
          else
            build_matcher(matched_count: 0)
          end
        end

        subject.perform(market_id, 'scheduled')

        # 3 rounds with matches + 1 round with 0 = 4 total
        expect(call_count).to eq(4)
      end

      it 'exits loop when budget exceeded' do
        sched.loop_budget_sec = 0

        matcher = build_matcher(matched_count: 2)
        allow(Matching::Engine).to receive(:new).and_return(matcher)

        subject.perform(market_id, 'scheduled')

        # Budget check runs before first round; loop exits without infinite iterations
      end

      it 'schedules follow-up when budget is exceeded' do
        sched.loop_budget_sec = 0

        allow(redis).to receive(:set).and_return(true)
        matcher = build_matcher(matched_count: 2)
        allow(Matching::Engine).to receive(:new).and_return(matcher)

        expect(Jobs::Matching::Worker).to receive(:perform_in)
          .with(1.0.seconds, market_id, 'followup')

        subject.perform(market_id, 'scheduled')
      end
    end

    context 'when lock is not acquired' do
      before do
        allow(subject).to receive(:with_redis_lock).and_yield(false)
      end

      it 'skips matching' do
        expect(Matching::Engine).not_to receive(:new)
        expect { subject.perform(market_id, 'scheduled') }.not_to raise_error
      end
    end

    context 'error handling' do
      before { allow(redis).to receive(:set).and_return(true) }

      it 're-raises errors from MatchEngine#perform' do
        matcher = double('MatchEngine', logger: double('Logger', respond_to?: false))
        allow(matcher).to receive(:perform).and_raise(RuntimeError, 'DB connection lost')
        allow(Matching::Engine).to receive(:new).and_return(matcher)

        expect { subject.perform(market_id, 'scheduled') }.to raise_error(RuntimeError, 'DB connection lost')
      end

      it 'does not raise when follow-up scheduling fails' do
        call_count = 0
        allow(Matching::Engine).to receive(:new) do
          call_count += 1
          build_matcher(matched_count: call_count == 1 ? 1 : 0)
        end

        # Make the dedup SET succeed but perform_in fails
        allow(Jobs::Matching::Worker).to receive(:perform_in).and_raise(Redis::CommandError, 'READONLY')

        expect { subject.perform(market_id, 'scheduled') }.not_to raise_error
      end
    end

    context 'with different trigger sources' do
      before do
        allow(redis).to receive(:set).and_return(true)

        matcher = build_matcher(matched_count: 0)
        allow(Matching::Engine).to receive(:new).and_return(matcher)
      end

      it 'accepts scheduled trigger' do
        expect { subject.perform(market_id, 'scheduled') }.not_to raise_error
      end

      it 'accepts event trigger' do
        expect { subject.perform(market_id, 'event') }.not_to raise_error
      end

      it 'accepts followup trigger' do
        expect { subject.perform(market_id, 'followup') }.not_to raise_error
      end
    end
  end

  describe 'follow-up scheduling' do
    before do
      allow(redis).to receive(:set).and_return(true)
    end

    it 'schedules follow-up when matches found' do
      call_count = 0
      allow(Matching::Engine).to receive(:new) do
        call_count += 1
        build_matcher(matched_count: call_count == 1 ? 1 : 0)
      end

      expect(Jobs::Matching::Worker).to receive(:perform_in)
        .with(1.0.seconds, market_id, 'followup')

      subject.perform(market_id, 'scheduled')
    end

    it 'skips follow-up when dedup key already exists' do
      allow(redis).to receive(:set) do |*args|
        key = args[0]
        opts = args.last.is_a?(Hash) ? args.last : {}
        if key == "match_followup:#{market_id}" && opts[:nx] == true
          false # dedup key already exists
        else
          true
        end
      end

      call_count = 0
      allow(Matching::Engine).to receive(:new) do
        call_count += 1
        build_matcher(matched_count: call_count == 1 ? 1 : 0)
      end

      expect(Jobs::Matching::Worker).not_to receive(:perform_in)
        .with(anything, market_id, 'followup')

      subject.perform(market_id, 'scheduled')
    end
  end

  describe 'waiting check scheduling' do
    before do
      allow(redis).to receive(:set).and_return(true)
    end

    it 'schedules waiting check when no matches and status is waiting' do
      matcher = build_matcher(matched_count: 0)
      allow(Matching::Engine).to receive(:new).and_return(matcher)
      allow(redis).to receive(:hget).with("orderMatcher:#{market_id}", "status").and_return("waiting")

      expect(Jobs::Matching::Worker).to receive(:perform_in)
        .with(10.seconds, market_id, 'waiting_check')

      subject.perform(market_id, 'scheduled')
    end

    it 'does not schedule waiting check when status is not waiting' do
      matcher = build_matcher(matched_count: 0)
      allow(Matching::Engine).to receive(:new).and_return(matcher)
      allow(redis).to receive(:hget).with("orderMatcher:#{market_id}", "status").and_return("matched")

      expect(Jobs::Matching::Worker).not_to receive(:perform_in)
        .with(anything, market_id, 'waiting_check')

      subject.perform(market_id, 'scheduled')
    end
  end

  describe 'lock release' do
    before { allow(redis).to receive(:set).and_return(true) }

    it 'releases the lock via Lua eval after completion' do
      matcher = build_matcher(matched_count: 0)
      allow(Matching::Engine).to receive(:new).and_return(matcher)

      expect(redis).to receive(:eval).with(anything, 1, "match_lock:#{market_id}", anything)

      subject.perform(market_id, 'scheduled')
    end
  end

  describe 'sidekiq configuration' do
    it 'has retry set to 3' do
      expect(described_class.sidekiq_options['retry']).to eq(3)
    end

    it 'has dead set to false' do
      expect(described_class.sidekiq_options['dead']).to eq(false)
    end
  end

  describe 'config reading' do
    it 'reads match_scheduler from Rails configuration' do
      allow(redis).to receive(:set).and_return(true)
      matcher = build_matcher(matched_count: 0)
      allow(Matching::Engine).to receive(:new).and_return(matcher)

      expect(Rails.configuration.x).to receive(:match_scheduler).and_return(sched)

      subject.perform(market_id, 'scheduled')
    end
  end
end
