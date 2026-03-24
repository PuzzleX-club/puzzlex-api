# spec/models/puzzlex_kline_spec.rb
require 'rails_helper'

RSpec.describe Trading::Kline, type: :model do
  describe 'associations' do
    it 'belongs to market' do
      # 也可使用 shoulda-matchers:
      # it { should belong_to(:market).class_name('Trading::Market').with_foreign_key('market_id') }

      kline = described_class.new
      expect(kline).to respond_to(:market)
    end
  end

  describe 'validations' do
    subject do
      # 通过 FactoryBot 或手动 new
      described_class.new(
        market: create(:market),    # 需先定义 factory :market
        interval: 60,
        timestamp: Time.now.to_i,    # 或整型区块时间
        open: 100.0,
        high: 120.0,
        low:  90.0,
        close: 110.0,
        volume: 10.0,
        turnover: 1000.0
      )
    end

    # presence: market_id, interval, timestamp, open, high, low, close, volume, turnover
    it 'is valid with all required fields' do
      expect(subject).to be_valid
    end

    context 'when a required field is missing' do
      it 'is invalid without market_id' do
        subject.market = nil
        expect(subject).not_to be_valid
        expect(subject.errors[:market_id]).to include(I18n.t('errors.messages.blank'))
      end

      it 'is invalid without interval' do
        subject.interval = nil
        expect(subject).not_to be_valid
        expect(subject.errors[:interval]).to include(I18n.t('errors.messages.blank'))
      end

      it 'is invalid without timestamp' do
        subject.timestamp = nil
        expect(subject).not_to be_valid
        expect(subject.errors[:timestamp]).to include(I18n.t('errors.messages.blank'))
      end

      it 'is invalid without open' do
        subject.open = nil
        expect(subject).not_to be_valid
        expect(subject.errors[:open]).to include(I18n.t('errors.messages.blank'))
      end

      it 'is invalid without high' do
        subject.high = nil
        expect(subject).not_to be_valid
        expect(subject.errors[:high]).to include(I18n.t('errors.messages.blank'))
      end

      it 'is invalid without low' do
        subject.low = nil
        expect(subject).not_to be_valid
        expect(subject.errors[:low]).to include(I18n.t('errors.messages.blank'))
      end

      it 'is invalid without close' do
        subject.close = nil
        expect(subject).not_to be_valid
        expect(subject.errors[:close]).to include(I18n.t('errors.messages.blank'))
      end

      it 'is invalid without volume' do
        subject.volume = nil
        expect(subject).not_to be_valid
        expect(subject.errors[:volume]).to include(I18n.t('errors.messages.blank'))
      end

      it 'is invalid without turnover' do
        subject.turnover = nil
        expect(subject).not_to be_valid
        expect(subject.errors[:turnover]).to include(I18n.t('errors.messages.blank'))
      end
    end

    # uniqueness: market_id, interval, timestamp
    context 'uniqueness' do
      it 'should be unique per market_id, interval, timestamp' do
        subject.save!  # 保存首条记录
        dup = described_class.new(
          market: subject.market,
          interval: subject.interval,
          timestamp: subject.timestamp,
          open: 200.0,
          high: 250.0,
          low:  190.0,
          close: 240.0,
          volume: 20.0,
          turnover: 2000.0
        )
        expect(dup).not_to be_valid
        # 错误描述由 model 定义
        expect(dup.errors[:market_id]).to include("should be unique per interval and timestamp")
      end
    end
  end
end