require 'rails_helper'

RSpec.describe MarketData::KlinePersister, type: :service do
  describe "#complete_kline_data" do
    before do
      @custom_market = create(:market, id: 12301)
    end

    let(:interval)  { 60 }
    let(:end_time)  { 1650000300 }  # 测试用的结束时间戳
    let(:persister) { described_class.new(market_id: @custom_market.id, interval: interval) }

    context "when no kline record exists" do
      context "and no fills exist" do
        it "returns 0 and does nothing" do
          expect {
            result = persister.complete_kline_data(end_time: end_time)
            expect(result).to eq(0)
          }.not_to change { Trading::Kline.count }
        end
      end

      context "and there is an earliest fill" do
        let!(:earliest_fill) do
          # 例如 block_timestamp=1650000007 => 非整分, 测试对齐逻辑
          create(:trading_order_fill,
                 market_id: @custom_market.id,
                 block_timestamp: 1650000007,
                 filled_amount: 2.0,
                 price_distribution: [{ "total_amount" => "600" }] )
        end

        it "starts from earliest fill's block_timestamp aligned down" do
          # interval=60 => align_timestamp_down(1650000007)=1650000000
          # end_time=1650000300 => 5区间 (1650000000,60,...,1650000300)
          # 如果KlineDataBuilder返回有成交 => 可能写入多条
          # => 可用 stub KlineDataBuilder 或做真实integration

          # Mock KlineDataBuilder，避免依赖另一个服务逻辑
          # => 默认把build_cycle_data[0]结果伪造
          fake_kline_data_no_trade = [0, "0","0","0","0","0","0" ]      # 无成交
          fake_kline_data_trade    = [0, "100","120","90","110","10","1000" ]  # 有成交

          # 定义一个切换：第一次/第二次调用不成交，后面有成交...
          # 可根据需要自定义
          allow(MarketData::KlineDataBuilder).to receive(:new).and_return(
            double("KlineBuilder", build_cycle_data: [fake_kline_data_trade])
          )

          expect {
            result = persister.complete_kline_data(end_time: end_time)
            # inserted_count => 如果循环写了N条 => N
            expect(result).to be >=1
          }.to change { Trading::Kline.count }.by_at_least(1)

          # 可校验: 第1条K线timestamp=1650000000, open=100.0, ...
          first_kline = Trading::Kline.where(market_id: @custom_market.id, interval: interval).order(:timestamp).first
          expect(first_kline.timestamp).to eq(1650000060)
          expect(first_kline.open).to eq(100.0)
          expect(first_kline.volume).to eq(10.0)
        end
      end
    end

    context "when there is existing kline record" do
      let!(:existing_kline) do
        create(:trading_kline,
               market_id: @custom_market.id,
               interval: interval,
               timestamp: 1650000060,  # 已存在
               open:99, high:110, low:80, close:100, volume:10, turnover:1000)
      end

      context "and no new fills after that timestamp" do
        it "creates 4 new kline records between 1650000060 and 1650000300, each with 0 volume" do
          # Mock KlineDataBuilder => 无成交
          allow(MarketData::KlineDataBuilder).to receive(:new).and_return(
            double("KlineBuilder", build_cycle_data: [[0,"0","0","0","0","0","0"]])
          )
          expect {
            result = persister.complete_kline_data(end_time: end_time)
            expect(result).to eq(4)
          }.to change { Trading::Kline.count }.by(4)

          # 1) 获取新插入的kline记录(大于existing_kline.timestamp)
          newly_created = Trading::Kline
                            .where("timestamp > ?", existing_kline.timestamp)
                            .order(:timestamp)

          # 2) 检查数量
          expect(newly_created.size).to eq(4)

          # 3) 校验字段：
          # - volume=0
          # - open/high/low/close都为previousKline.close
          # - timestamp依照 1分钟step(60秒) 顺序递增
          prev_close = existing_kline.close
          current_ts = existing_kline.timestamp + interval # => 1650000060 + 60 => 1650000120

          newly_created.each do |k|
            expect(k.timestamp).to eq(current_ts)
            # 校验 open/high/low/close => 都等于prev_close
            expect(k.open).to  eq(prev_close)
            expect(k.high).to  eq(prev_close)
            expect(k.low).to   eq(prev_close)
            expect(k.close).to eq(prev_close)

            # volume=0, turnover=0
            expect(k.volume).to   eq(0.0)
            expect(k.turnover).to eq(0.0)

            # 准备下一个区间
            current_ts += interval
          end
        end
      end

      context "and there are new fills after that timestamp" do
        let!(:new_fill_1) do
          # block_timestamp=1650000120 => 区间1
          create(:trading_order_fill,
                 market: @custom_market,
                 block_timestamp: 1650000120,
                 filled_amount: 3.0,
                 price_distribution: [{ "total_amount" => "900" }] )
        end

        let!(:new_fill_2) do
          # block_timestamp=1650000240 => 区间2, 两次间隔 120秒
          create(:trading_order_fill,
                 market: @custom_market,
                 block_timestamp: 1650000240,
                 filled_amount: 4.0,
                 price_distribution: [{ "total_amount" => "1200" }] )
        end

        it "resumes from existing_kline.timestamp + step_seconds, merges intervals without fills as 0-volume, and includes new fill volumes" do
          # existing_kline.timestamp=1650000060 + interval=60 => start_ts=1650000120
          # end_time=1650000300 => TS区间：1650000120, 1650000180, 1650000240, 1650000300

          # 我们可mock builder或让其真实调用
          # 若想真实测试请删除这段 allow(...).
          # 这里示例: 让KlineDataBuilder返回 [0,"(string)","(string)","(string)","(string)","(volume)","(turnover)"]
          # 不再mock => 或者仅mock到build_cycle_data只返回1个区间 => 这里演示真实写法(注释掉)...

          # 如果确实想mock:
          # allow(MarketData::KlineDataBuilder).to receive(:new).and_return(
          #   double("KlineBuilder", build_cycle_data: [[0,"300","300","300","300","3","900"]])
          # )

          expect {
            result = persister.complete_kline_data(end_time: end_time)
            # inserted_count => 这里根据区间 step=60, start=1650000120 => end=1650000300(共3~4个区间)
            # 2个区间带有成交 => volume>0, 其余区间 volume=0
            expect(result).to eq(4)
          }.to change { Trading::Kline.count }.by(4)

          # 获取“新”插入的kline记录
          newly_created = Trading::Kline
                            .where("timestamp > ?", existing_kline.timestamp)
                            .order(:timestamp)

          # => timestamps 可能是: 1650000120,1650000180,1650000240,1650000300
          # (最后一格区间可能会不会有 fill, 取决于 step & end_time)

          # 校验第一个有填充的区间
          fill1_kline = newly_created.find_by(timestamp: 1650000120)
          # 计算price= total_amount/fill_amount=900/3=300
          expect(fill1_kline.volume).to eq(3.0)
          expect(fill1_kline.turnover).to eq(900.0)
          expect(fill1_kline.open).to eq(300.0)
          expect(fill1_kline.high).to eq(300.0)
          expect(fill1_kline.low).to eq(300.0)
          expect(fill1_kline.close).to eq(300.0)

          # 校验中间可能没有fill => fallback 0-volume => open=close=上一条收盘价
          # 假如 1650000180 没有 fill => volume=0, open=300, close=300
          # (若interval60 => new_fill_2=1650000240 => 跳过1650000180)
          no_trade_kline = newly_created.find_by(timestamp: 1650000180)
          if no_trade_kline
            expect(no_trade_kline.volume).to eq(0.0)
            expect(no_trade_kline.open).to  eq(300.0)  # fallback
            expect(no_trade_kline.close).to eq(300.0)
          end

          # 校验第二个有填充的区间(1650000240)
          fill2_kline = newly_created.find_by(timestamp: 1650000240)
          # price=1200/4=300
          expect(fill2_kline.volume).to eq(4.0)
          expect(fill2_kline.turnover).to eq(1200.0)
          expect(fill2_kline.open).to eq(300.0)
          expect(fill2_kline.high).to eq(300.0)
          expect(fill2_kline.low).to eq(300.0)
          expect(fill2_kline.close).to eq(300.0)

          # 若 1650000300 再无fill => volume=0 => fallback
          last_kline = newly_created.find_by(timestamp: 1650000300)
          if last_kline
            expect(last_kline.volume).to eq(0.0)
            expect(last_kline.open).to  eq(300.0)  # 承接上一条close
            expect(last_kline.close).to eq(300.0)
          end
        end
      end

      context "and builder returns no trade => fallback to prev_kline close" do
        it "uses prev_kline close" do
          # 让 builder返回 [0,"0","0","0","0","0","0"] => no trade
          allow(MarketData::KlineDataBuilder).to receive(:new).and_return(
            double("KlineBuilder", build_cycle_data: [[0,"0","0","0","0","0","0"]])
          )

          expect {
            result = persister.complete_kline_data(end_time: 1650000120)
            expect(result).to eq(1)  # 一条记录(1650000120) 但volume=0
          }.to change { Trading::Kline.count }.by(1)

          # 检查新纪录
          new_no_trade = Trading::Kline.find_by(timestamp: 1650000120, market_id: @custom_market.id)
          expect(new_no_trade.volume).to eq(0.0)
          expect(new_no_trade.open).to  eq(existing_kline.close)  # 用上一条close
          expect(new_no_trade.high).to  eq(existing_kline.close)
          expect(new_no_trade.low).to   eq(existing_kline.close)
          expect(new_no_trade.close).to eq(existing_kline.close)
        end
      end
    end
  end

  describe "#persist_kline_array" do
    before do
      @custom_market = create(:market, id: 12301)
    end

    let(:interval)  { 60 }
    let(:persister) { described_class.new(market_id: @custom_market.id, interval: interval) }


    # 模拟2条K线, timestamps=1000和1060
    let(:kline_array) do
      [
        [1000, "100.0", "120.0", "90.0", "110.0", "10.0", "1000.0"],
        [1060, "110.0", "130.0", "100.0", "120.0", "20.0", "2400.0"]
      ]
    end

    it "creates new kline records if none exist" do
      expect {
        persister.persist_kline_array(@custom_market.id, interval, kline_array)
      }.to change { Trading::Kline.count }.by(2)

      rec1 = Trading::Kline.find_by(market: @custom_market, interval: interval, timestamp: 1000)
      expect(rec1).not_to be_nil
      expect(rec1.open).to eq(100.0)
      expect(rec1.high).to eq(120.0)
      expect(rec1.low).to  eq(90.0)
      expect(rec1.close).to eq(110.0)
      expect(rec1.volume).to eq(10.0)
      expect(rec1.turnover).to eq(1000.0)

      rec2 = Trading::Kline.find_by(market: @custom_market, interval: interval, timestamp: 1060)
      expect(rec2).not_to be_nil
      expect(rec2.volume).to eq(20.0)
      expect(rec2.turnover).to eq(2400.0)
    end

    it "updates existing record if the same market/interval/timestamp already exists" do
      # 先建一条旧记录:
      existing = create(:trading_kline,
                        market: @custom_market,
                        interval: interval,
                        timestamp: 1000,
                        open: 99.0,
                        close: 100.0
      )
      # kline_array里第一条timestamp=1000，会对这个 existing 进行更新
      # 两条kline的情况下，数据库会增加一条记录

      expect {
        persister.persist_kline_array(@custom_market.id, interval, kline_array)
      }.to change { Trading::Kline.count }.by(1)

      existing.reload
      # 检查存在的那条线是否被更新:
      expect(existing.open).to  eq(100.0)
      expect(existing.high).to  eq(120.0)
      expect(existing.low).to   eq(90.0)
      expect(existing.close).to eq(110.0)
      expect(existing.volume).to eq(10.0)
      expect(existing.turnover).to eq(1000.0)
    end
  end
end