# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Realtime::HeartbeatService, redis: :real do
  include ActiveSupport::Testing::TimeHelpers

  let(:topic) { 'market_123_trades' }

  before do
    # 清理Redis测试数据
    Redis.current.del("heartbeat_last_update:#{topic}")
    Redis.current.del("heartbeat_sent:#{topic}")
  end

  describe '.record_update' do
    it 'records update timestamp in Redis' do
      freeze_time do
        described_class.record_update(topic)

        stored_value = Redis.current.get("heartbeat_last_update:#{topic}")
        expect(stored_value.to_i).to eq(Time.current.to_i)
      end
    end

    it 'sets expiry time to 2 hours' do
      described_class.record_update(topic)

      ttl = Redis.current.ttl("heartbeat_last_update:#{topic}")
      expect(ttl).to be_within(5).of(7200) # 2 hours
    end

    it 'logs debug message' do
      expect(Rails.logger).to receive(:debug).with(/Recorded update for #{topic}/)
      described_class.record_update(topic)
    end
  end

  describe '.last_update_time' do
    context 'when update exists' do
      before do
        freeze_time do
          described_class.record_update(topic)
        end
      end

      it 'returns the update timestamp' do
        freeze_time do
          result = described_class.last_update_time(topic)
          expect(result).to eq(Time.current.to_i)
        end
      end
    end

    context 'when no update exists' do
      it 'returns nil' do
        result = described_class.last_update_time(topic)
        expect(result).to be_nil
      end
    end
  end

  describe '.should_send_heartbeat?' do
    let(:interval) { 60 }

    context 'when no activity has been recorded' do
      it 'returns true' do
        expect(described_class.should_send_heartbeat?(topic, interval)).to be true
      end
    end

    context 'when update was recorded recently' do
      before do
        freeze_time do
          described_class.record_update(topic)
        end
      end

      it 'returns false if within interval' do
        travel 30.seconds do
          expect(described_class.should_send_heartbeat?(topic, interval)).to be false
        end
      end

      it 'returns true if exceeds interval' do
        travel 61.seconds do
          expect(described_class.should_send_heartbeat?(topic, interval)).to be true
        end
      end
    end

    context 'when heartbeat was sent recently' do
      before do
        freeze_time do
          described_class.record_heartbeat(topic)
        end
      end

      it 'returns false if within interval' do
        travel 30.seconds do
          expect(described_class.should_send_heartbeat?(topic, interval)).to be false
        end
      end
    end

    context 'when both update and heartbeat exist' do
      it 'uses the most recent activity time' do
        freeze_time do
          # 在时间 T 时记录更新
          described_class.record_update(topic)
        end

        # 20秒后记录心跳
        travel 20.seconds do
          described_class.record_heartbeat(topic)
        end

        # 再过20秒（距离心跳20秒，距离更新40秒）
        travel 40.seconds do
          # 距离最近的活动（心跳）只有20秒，还在60秒间隔内
          expect(described_class.should_send_heartbeat?(topic, interval)).to be false
        end

        travel_back # 恢复时间
      end
    end
  end

  describe '.record_heartbeat' do
    it 'records heartbeat timestamp in Redis' do
      freeze_time do
        described_class.record_heartbeat(topic)

        stored_value = Redis.current.get("heartbeat_sent:#{topic}")
        expect(stored_value.to_i).to eq(Time.current.to_i)
      end
    end

    it 'sets expiry time to 2 hours' do
      described_class.record_heartbeat(topic)

      ttl = Redis.current.ttl("heartbeat_sent:#{topic}")
      expect(ttl).to be_within(5).of(7200)
    end

    it 'logs debug message' do
      expect(Rails.logger).to receive(:debug).with(/Recorded heartbeat for #{topic}/)
      described_class.record_heartbeat(topic)
    end
  end

  describe '.last_heartbeat_time' do
    context 'when heartbeat exists' do
      before do
        freeze_time do
          described_class.record_heartbeat(topic)
        end
      end

      it 'returns the heartbeat timestamp' do
        freeze_time do
          result = described_class.last_heartbeat_time(topic)
          expect(result).to eq(Time.current.to_i)
        end
      end
    end

    context 'when no heartbeat exists' do
      it 'returns nil' do
        result = described_class.last_heartbeat_time(topic)
        expect(result).to be_nil
      end
    end
  end

  describe '.recently_sent_heartbeat?' do
    let(:grace_period) { 5 }

    context 'when no heartbeat exists' do
      it 'returns false' do
        expect(described_class.recently_sent_heartbeat?(topic, grace_period)).to be false
      end
    end

    context 'when heartbeat is within grace period' do
      before do
        freeze_time do
          described_class.record_heartbeat(topic)
        end
      end

      it 'returns true' do
        travel 3.seconds do
          expect(described_class.recently_sent_heartbeat?(topic, grace_period)).to be true
        end
      end
    end

    context 'when heartbeat is outside grace period' do
      before do
        freeze_time do
          described_class.record_heartbeat(topic)
        end
      end

      it 'returns false' do
        travel 6.seconds do
          expect(described_class.recently_sent_heartbeat?(topic, grace_period)).to be false
        end
      end
    end
  end

  describe '.cleanup_expired_records' do
    before do
      # 创建一些测试数据
      described_class.record_update('topic1')
      described_class.record_heartbeat('topic1')
      described_class.record_update('topic2')
      described_class.record_heartbeat('topic2')
    end

    context 'when cleaning specific topics' do
      it 'removes only specified topic records' do
        result = described_class.cleanup_expired_records(['topic1'])

        expect(result).to eq(2) # update + heartbeat
        expect(described_class.last_update_time('topic1')).to be_nil
        expect(described_class.last_heartbeat_time('topic1')).to be_nil
        expect(described_class.last_update_time('topic2')).not_to be_nil
        expect(described_class.last_heartbeat_time('topic2')).not_to be_nil
      end
    end

    context 'when cleaning all topics' do
      it 'removes all heartbeat records' do
        result = described_class.cleanup_expired_records([])

        expect(result).to be >= 4 # 至少4个键（可能有其他测试残留）
        expect(described_class.last_update_time('topic1')).to be_nil
        expect(described_class.last_heartbeat_time('topic1')).to be_nil
        expect(described_class.last_update_time('topic2')).to be_nil
        expect(described_class.last_heartbeat_time('topic2')).to be_nil
      end

      it 'logs cleanup result' do
        expect(Rails.logger).to receive(:info).with(/Cleaned \d+ expired heartbeat records/)
        described_class.cleanup_expired_records([])
      end
    end
  end
end
