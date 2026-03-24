# app/models/trading/market.rb
module Trading
  class Market < ApplicationRecord
    self.primary_key = 'market_id'
    has_many :klines, class_name: 'Trading::Kline', foreign_key: :market_id, primary_key: :market_id, dependent: :destroy

    # ============================================
    # 支付类型枚举
    # ============================================
    # 显式声明 attribute 类型，避免在没有数据库列时出错
    # 如果数据库有此列，此声明会被忽略；如果没有，则提供虚拟属性
    attribute :payment_type, :integer, default: 1

    # 定义市场支付方式
    enum payment_type: {
      eth: 1,    # ETH（原生代币）支付
      erc20: 2   # ERC20 代币支付
    }

    # ============================================
    # 验证
    # ============================================
    validates :name, :base_currency, :quote_currency, :price_address, :item_id, :market_id, presence: true
    validates :market_id, uniqueness: true
    validates :base_currency, uniqueness: { scope: :quote_currency, message: "和报价货币的组合必须唯一" }

    # 市场创建后立即注册到Redis订单撮合系统
    after_create :register_to_matcher

    private

    # 将市场注册到Redis撮合系统
    # 实时回调: 零延迟,新市场立即参与撮合
    def register_to_matcher
      redis_key = "orderMatcher:#{market_id}"
      market_id_str = market_id.to_s
      db_id_str = id.to_s

      # 兼容配置差异：同时写入应用Redis与Sidekiq Redis，避免 market_list 跨 DB 不一致导致撮合扫描为空。
      write_market_to_app_redis(redis_key, market_id_str, db_id_str)
      write_market_to_sidekiq_redis(redis_key, market_id_str, db_id_str)

      Rails.logger.info "[MARKET] Market #{market_id} registered to Redis matching system"
    rescue StandardError => e
      # 注册失败不应阻止市场创建,记录错误并继续
      Rails.logger.error "[MARKET] Market #{market_id} Redis registration failed: #{e.message}"
    end

    def write_market_to_app_redis(redis_key, market_id_str, db_id_str)
      Redis.current.hset(redis_key, "market_id", market_id_str)
      Redis.current.hset(redis_key, "status", "waiting")
      Redis.current.hset(redis_key, "db_id", db_id_str)
      Redis.current.sadd("market_list", market_id_str)
    end

    def write_market_to_sidekiq_redis(redis_key, market_id_str, db_id_str)
      Sidekiq.redis do |conn|
        conn.hset(redis_key, "market_id", market_id_str)
        conn.hset(redis_key, "status", "waiting")
        conn.hset(redis_key, "db_id", db_id_str)
        conn.sadd("market_list", market_id_str)
      end
    end
  end
end
