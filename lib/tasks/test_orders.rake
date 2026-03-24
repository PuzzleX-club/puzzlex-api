namespace :test do
  desc "Create test orders for matching - generates multiple buy/sell orders to increase liquidity"
  task :create_orders => :environment do
    market_id = ENV['MARKET_ID'] || '30001'
    num_orders = (ENV['NUM_ORDERS'] || '10').to_i
    
    puts "Creating #{num_orders} test orders for market #{market_id}..."

    # 清理已有的测试订单（可选）
    if ENV['CLEAN'] == 'true'
      puts "Cleaning existing orders..."
      Trading::Order.where(market_id: market_id).destroy_all
    end

    created_orders = []
    base_price = 100.0
    
    # 创建买单（出价较低）
    (num_orders / 2).times do |i|
      buy_price = base_price - rand(1..10)  # 90-99之间的买单价格
      buy_qty = rand(1..5)  # 1-5的数量
      
      order = Trading::Order.create!(
        order_hash: "0xBuyOrder#{Time.now.to_i}#{i}",
        market_id: market_id,
        order_direction: "Offer",  # 买单
        onchain_status: "validated",
        start_price: buy_price,
        end_price: buy_price,
        offer_start_amount: buy_qty,
        offer_end_amount: buy_qty,
        consideration_start_amount: buy_price * buy_qty,
        consideration_end_amount: buy_price * buy_qty,
        offerer: "0xBuyer#{i}",
        start_time: (Time.now.to_i - 3600).to_s,  # 1小时前开始
        end_time: (Time.now.to_i + 86400).to_s,   # 24小时后过期
        counter: 0,
        offer_token: "0x0000000000000000000000000000000000000000",  # ETH
        offer_identifier: "0",
        consideration_token: "0x1234567890123456789012345678901234567890",  # Token
        consideration_identifier: "#{1000 + i}",
        parameters: {},
        signature: "0xsignature#{i}",
        is_validated: true,
        is_cancelled: false,
        total_filled: 0,
        total_size: buy_qty
      )
      created_orders << order
      puts "Created buy order: #{buy_price} @ #{buy_qty} (ID: #{order.id})"
    end

    # 创建卖单（要价较高，但有部分与买单重叠）
    (num_orders / 2).times do |i|
      sell_price = base_price + rand(-5..10)  # 95-110之间的卖单价格（有重叠区间）
      sell_qty = rand(1..5)  # 1-5的数量
      
      order = Trading::Order.create!(
        order_hash: "0xSellOrder#{Time.now.to_i}#{i}",
        market_id: market_id,
        order_direction: "List",  # 卖单
        onchain_status: "validated",
        start_price: sell_price,
        end_price: sell_price,
        offer_start_amount: sell_qty,
        offer_end_amount: sell_qty,
        consideration_start_amount: sell_price * sell_qty,
        consideration_end_amount: sell_price * sell_qty,
        offerer: "0xSeller#{i}",
        start_time: (Time.now.to_i - 3600).to_s,  # 1小时前开始
        end_time: (Time.now.to_i + 86400).to_s,   # 24小时后过期
        counter: 0,
        offer_token: "0x1234567890123456789012345678901234567890",  # Token
        offer_identifier: "#{2000 + i}",
        consideration_token: "0x0000000000000000000000000000000000000000",  # ETH
        consideration_identifier: "0",
        parameters: {},
        signature: "0xsignature_sell#{i}",
        is_validated: true,
        is_cancelled: false,
        total_filled: 0,
        total_size: sell_qty
      )
      created_orders << order
      puts "Created sell order: #{sell_price} @ #{sell_qty} (ID: #{order.id})"
    end

    puts "\n✅ Created #{created_orders.length} test orders successfully!"
    puts "📊 Summary:"
    puts "   Buy orders: #{created_orders.count { |o| o.order_direction == 'Offer' }}"
    puts "   Sell orders: #{created_orders.count { |o| o.order_direction == 'List' }}"
    puts "   Market ID: #{market_id}"
    
    # 显示价格范围统计
    buy_prices = created_orders.select { |o| o.order_direction == 'Offer' }.map(&:start_price)
    sell_prices = created_orders.select { |o| o.order_direction == 'List' }.map(&:start_price)
    
    if buy_prices.any? && sell_prices.any?
      puts "   Buy price range: #{buy_prices.min} - #{buy_prices.max}"
      puts "   Sell price range: #{sell_prices.min} - #{sell_prices.max}"
      
      # 检查价格重叠区间
      max_buy = buy_prices.max
      min_sell = sell_prices.min
      if max_buy >= min_sell
        puts "   💰 Price overlap detected: #{min_sell} - #{max_buy} (orders should match!)"
      else
        puts "   ⚠️  No price overlap: gap between #{max_buy} and #{min_sell}"
      end
    end
    
    puts "\n🚀 Run order matching with:"
    puts "   rails runner 'Matching::Engine.new(#{market_id}).perform'"
  end

  desc "Show order book for a market"
  task :show_orderbook => :environment do
    market_id = ENV['MARKET_ID'] || '30001'
    
    puts "📚 Order Book for Market #{market_id}:"
    puts "=" * 50
    
    orders = Trading::Order.where(market_id: market_id, onchain_status: %w[pending validated partially_filled])
    
    if orders.empty?
      puts "No active orders found. Create some with: rake test:create_orders"
      next
    end
    
    buy_orders = orders.where(order_direction: 'Offer').order(start_price: :desc)
    sell_orders = orders.where(order_direction: 'List').order(start_price: :asc)
    
    puts "\nBUY ORDERS (Bids):"
    puts "Price\t\tQty\t\tOrder Hash"
    puts "-" * 40
    buy_orders.each do |order|
      puts "#{order.start_price}\t\t#{order.offer_start_amount}\t\t#{order.order_hash[0..15]}..."
    end
    
    puts "\nSELL ORDERS (Asks):"
    puts "Price\t\tQty\t\tOrder Hash"
    puts "-" * 40
    sell_orders.each do |order|
      puts "#{order.start_price}\t\t#{order.offer_start_amount}\t\t#{order.order_hash[0..15]}..."
    end
    
    puts "\n📊 Statistics:"
    puts "Total active orders: #{orders.count}"
    puts "Buy orders: #{buy_orders.count}"
    puts "Sell orders: #{sell_orders.count}"
    
    if buy_orders.any? && sell_orders.any?
      best_bid = buy_orders.first.start_price
      best_ask = sell_orders.first.start_price
      spread = best_ask - best_bid
      puts "Best bid: #{best_bid}"
      puts "Best ask: #{best_ask}"
      puts "Spread: #{spread} (#{spread > 0 ? 'No overlap' : 'OVERLAP - should match!'})"
    end
  end

  desc "Clean all test orders"
  task :clean_orders => :environment do
    market_id = ENV['MARKET_ID'] || '30001'
    
    count = Trading::Order.where(market_id: market_id).count
    Trading::Order.where(market_id: market_id).destroy_all
    
    puts "🧹 Cleaned #{count} orders from market #{market_id}"
  end
end
