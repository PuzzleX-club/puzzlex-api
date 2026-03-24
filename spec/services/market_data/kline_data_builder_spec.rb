require 'rails_helper'

RSpec.describe MarketData::KlineDataBuilder, type: :service do
  let(:end_time) { 1650000300 }   # 当前时间戳(秒)
  let(:interval) { 60 }             # 1分钟周期(例如)
  let(:steps)    { 1 }              # 本例暂时无需 steps, 只是示例
  # kline已经可以正确的通过market_id进行生成，fill数据需要和market_id适配才能通过测试
  # market factory generates market_id = "#{item_id}#{currency_number}" where RON = '00'
  # So item_id=123 + RON -> "12300"
  let(:market_id) { "12300" }       # 匹配 create(:market, item_id: 123) 生成的 market_id
  # 这里先 mock 出 MarketData::MarketIdParser.new(market_id: ...)
  # 可以在测试文件中用 allow(...).to receive(...) 来替代

  subject do
    described_class.new(
      market_id: market_id,
      interval: interval,
      end_time: end_time,
      steps: steps
    )
  end

  # 如果 MarketData::KlineDataBuilder 内部会调用
  # MarketData::MarketIdParser.new(market_id: ...)
  # 使用stub, 让它返回一个伪 market对象，这个对象通过 double 创建，有 item 和 price_address
  before do
    fake_market = double(:market, item_id: 123, price_address: "0x0000123456")
    allow(MarketData::MarketIdParser).to receive(:new).with(market_id:market_id).and_return(fake_market)
  end

  describe "#build_cycle_data" do
    context "when there are no fills in given time range" do
      it "returns default kline data" do
        # 假设数据库中没有匹配的fills
        # 默认kline元素首位是时间戳，其余都是0，检验除首位的元素是否都是0
        kline_data = subject.build_cycle_data
        default_kline = subject.default_kline_data(60)
        # 这唯一fill被跳过 => 结果= default_kline_data
        (1..6).each do |idx|
          expect(kline_data[0][idx]).to eq(default_kline[0][idx])
        end
      end
    end

    context "when fill has multiple price_distribution entries" do
      before do

        custom_item = create(:trading_order_item, id: 123)
        custom_market = create(:market, item_id: 123)

        create(:trading_order_fill,
               order_item: custom_item,
               market: custom_market,
               block_timestamp: end_time - 30,  # 在 [start_time, end_time] 之内
               filled_amount: 2.0,
               price_distribution: [
                 {
                   "token_address" => "0x0000123456",
                   "item_type" => 2,           # 2示例: ERC721
                   "token_id" => "1001",       # NFT的tokenId, 如果非NFT可写"0"
                   "recipients" => [
                     { "address" => "0xRecipient1", "amount" => "350" },
                     { "address" => "0xRecipient2", "amount" => "300" }
                   ],
                   "total_amount" => "650"     # 字符串表示总额/总数量
                 }
               ]
        )
        # 也可再创建更多 fill
        create(:trading_order_fill,
               order_item: custom_item,
               market: custom_market,
               block_timestamp: end_time - 10,
               filled_amount: 1.0,
               price_distribution: [
                 {
                   "token_address" => "0x0000123456",
                   "item_type" => 2,           # 2示例: ERC721
                   "token_id" => "1001",       # NFT的tokenId, 如果非NFT可写"0"
                   "recipients" => [
                     { "address" => "0xRecipient1", "amount" => "300" },
                     { "address" => "0xRecipient2", "amount" => "300" }
                   ],
                   "total_amount" => "600"     # 字符串表示总额/总数量
                 }
               ]
        )

      end

      it "calculates open/high/low/close/volume/turnover" do
        # 设定 @start_time = end_time - 60
        # fills 在 [-30, -10]秒都有 => all in range
        kline_data_all = subject.build_cycle_data
        # => kline_data 形如 [ @start_time, open, high, low, close, volume, turnover ]

        expect(kline_data_all.size).to eq(1)

        kline_data = kline_data_all[0]

        timestamp_val    = kline_data[0]
        open_price_str    = kline_data[1]
        high_price_str    = kline_data[2]
        low_price_str     = kline_data[3]
        close_price_str   = kline_data[4]
        total_volume_str  = kline_data[5]
        turnover_str      = kline_data[6]

        # 检查 start_time 是否是 (@end_time - interval)
        expect(timestamp_val).to eq(end_time)

        # 第一个fill price=650/2=325 => open价格, low价格
        # 第二个fill price=600 => close价格, high价格
        # low=600, volume=3(2+1), turnover= (2*325 + 1*600)= 1250

        expect(open_price_str.to_f).to eq(325.00)
        expect(high_price_str.to_f).to eq(600.00)
        expect(low_price_str.to_f).to  eq(325.00)
        expect(close_price_str.to_f).to eq(600.00)
        expect(total_volume_str.to_f).to eq(3.00)
        expect(turnover_str.to_f).to eq(1250.0)
      end
    end

    context "when dealing with multiple intervals across a large K-line span" do
      let(:steps)    { 3 }   # 生成3个区间
      let(:interval) { 60 }  # 每区间60秒
      before do
        # re-stub is optional if same market_id
        # fill in 3 intervals:
        custom_item = create(:trading_order_item, id: 123)
        custom_market = create(:market, item_id: 123)

        # 1) end_time - 30 => last interval
        create(:trading_order_fill,
               order_item: custom_item,
               market: custom_market,
               block_timestamp: end_time - 150,
               filled_amount: 1.0,
               price_distribution: [
                 {
                   "token_address" => "0x0000123456",
                   "total_amount"  => "310"
                 }
               ]
        )

        # 2) end_time - 90 => second interval
        create(:trading_order_fill,
               order_item: custom_item,
               market: custom_market,
               block_timestamp: end_time - 90,
               filled_amount: 2.0,
               price_distribution: [
                 {
                   "token_address" => "0x0000123456",
                   "total_amount"  => "600"
                 }
               ]
        )

        # 3) end_time - 150 => third interval
        create(:trading_order_fill,
               order_item: custom_item,
               market: custom_market,
               block_timestamp: end_time - 30,
               filled_amount: 3.0,
               price_distribution: [
                 {
                   "token_address" => "0x0000123456",
                   "total_amount"  => "990"
                 }
               ]
        )
      end

      it "generates K-line data for each interval" do
        # build_cycle_data => 3 intervals => [kline_of_interval0, interval1, interval2]
        kline_data_all = subject.build_cycle_data

        # 根据KlineDataBuilder实现, 可能是一个多行数组, e.g. [ [start0,open0,high0,low0,close0,vol0,turn0], [start1, ...], [start2, ...] ]
        expect(kline_data_all.size).to eq(3)

        # intervals order: [ end_time -60, end_time], [end_time -120, end_time-60], [end_time-180, end_time-120]
        # 具体看internal sorted
        first_kline = kline_data_all[0]   # 最近区间
        second_kline= kline_data_all[1]
        third_kline = kline_data_all[2]

        # fill1 => end_time-150 => total_amount=310 / fill=1 => price=310 => open/high/low/close=300
        # fill2 => end_time-90 => => price=600/2=300
        # fill3 => end_time-30 => => 990/3=330
        # => 3 intervals => each price=300, volume= (1,2,3), turnover= (1*300=300,2*300=600,3*300=900)
        expect(first_kline[1].to_f).to eq(310.0) # open
        expect(first_kline[5].to_f).to eq(1.0)   # volume
        expect(first_kline[6].to_f).to eq(310.0) # turnover

        expect(second_kline[1].to_f).to eq(300.0)
        expect(second_kline[5].to_f).to eq(2.0)
        expect(second_kline[6].to_f).to eq(600.0)

        expect(third_kline[1].to_f).to eq(330.0)
        expect(third_kline[5].to_f).to eq(3.0)
        expect(third_kline[6].to_f).to eq(990.0)
      end
    end

    context "when fill has multiple price_distribution entries" do
      before do
        custom_item = create(:trading_order_item, id: 123)
        custom_market = create(:market, item_id: 123)
        create(:trading_order_fill,
               order_item: custom_item,
               market: custom_market,
               block_timestamp: end_time - 30,
               filled_amount: 10,
               price_distribution: [
                 {"total_amount" => "100.0", "token_address" => "0x0000123456"},
                 {"total_amount" => "200.0", "token_address" => "0xabcdef7890"}
               ],
        )
      end

      it "skips that fill record" do
        # because code says: "next unless fill.price_distribution.size == 1"
        kline_data = subject.build_cycle_data
        default_kline = subject.default_kline_data(60)
        # 这唯一fill被跳过 => 结果= default_kline_data
        (1..6).each do |idx|
          expect(kline_data[0][idx]).to eq(default_kline[0][idx])
        end

      end
    end
  end
end
