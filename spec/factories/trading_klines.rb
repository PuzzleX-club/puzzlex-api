# frozen_string_literal: true

# spec/factories/puzzlex_kline.rb
# K线数据工厂

FactoryBot.define do
  factory :trading_kline, class: 'Trading::Kline' do
    association :market, factory: :market

    interval { 60 } # 1分钟K线
    timestamp { Time.current.to_i }
    open { 100.0 }
    high { 120.0 }
    low { 90.0 }
    close { 110.0 }
    volume { 10.0 }
    turnover { 1000.0 }

    # === Traits ===

    # 1分钟K线
    trait :one_minute do
      interval { 60 }
    end

    # 5分钟K线
    trait :five_minutes do
      interval { 300 }
    end

    # 15分钟K线
    trait :fifteen_minutes do
      interval { 900 }
    end

    # 1小时K线
    trait :one_hour do
      interval { 3600 }
    end

    # 1天K线
    trait :one_day do
      interval { 86_400 }
    end

    # 上涨K线
    trait :bullish do
      open { 100.0 }
      close { 120.0 }
      high { 125.0 }
      low { 95.0 }
    end

    # 下跌K线
    trait :bearish do
      open { 120.0 }
      close { 100.0 }
      high { 125.0 }
      low { 95.0 }
    end

    # 高成交量
    trait :high_volume do
      volume { 1000.0 }
      turnover { 100_000.0 }
    end

    # 零成交量
    trait :zero_volume do
      volume { 0.0 }
      turnover { 0.0 }
    end

    # 指定时间的K线
    trait :at_time do
      transient do
        target_time { Time.current }
      end

      timestamp { target_time.to_i }
    end
  end
end
