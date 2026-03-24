# frozen_string_literal: true

module Jobs
  module MarketData
  # 市场同步任务 - 定期扫描数据库市场并同步到Redis
  #
  # 职责:
  # 1. 从数据库获取所有市场
  # 2. 从Redis获取已注册的市场
  # 3. 发现并注册新市场
  # 4. 修复缺失或损坏的市场键
  #
  # 执行频率:
  # - 生产环境: 每10分钟
  # - 测试环境: 每1分钟 (方便验证)
  #
  # 设计理念:
  # - 与 Jobs::Matching::DispatcherJob 解耦，专注于市场发现
  # - 低频运行,不影响高频撮合调度
  # - 容错处理,防止Redis数据丢失
  #
    module Sync
      class MarketRegistryJob
        include Sidekiq::Job

        sidekiq_options queue: :scheduler, retry: 3

        def perform
      # Leader选举检查：只有Leader实例执行全局同步
      begin
        unless Sidekiq::Election::Service.leader?
          Rails.logger.debug "[MarketData::Sync::MarketRegistryJob] 非Leader实例，跳过同步"
          return
        end
      rescue => e
        Rails.logger.error "[MarketData::Sync::MarketRegistryJob] 选举服务异常: #{e.message}，跳过本次同步"
        return
      end

      Rails.logger.info "[MarketData::Sync::MarketRegistryJob] 🔄 开始市场同步任务 (Leader)"

      stats = {
        db_markets: 0,
        redis_markets: 0,
        new_markets: 0,
        fixed_markets: 0
      }

      begin
        # 1. 从数据库获取所有市场ID
        db_market_ids = fetch_db_markets
        stats[:db_markets] = db_market_ids.size
        Rails.logger.info "[MarketData::Sync::MarketRegistryJob] 📊 数据库市场数: #{stats[:db_markets]}"

        # 2. 从Redis获取已注册的市场
        redis_market_ids = fetch_redis_markets
        stats[:redis_markets] = redis_market_ids.size
        Rails.logger.info "[MarketData::Sync::MarketRegistryJob] 📊 Redis已注册市场数: #{stats[:redis_markets]}"

        # 3. 发现新市场 (在数据库中但不在Redis中)
        new_market_ids = db_market_ids - redis_market_ids
        stats[:new_markets] = new_market_ids.size

        if new_market_ids.any?
          Rails.logger.info "[MarketData::Sync::MarketRegistryJob] 🆕 发现 #{new_market_ids.size} 个新市场: #{new_market_ids.join(', ')}"
          register_markets(new_market_ids)
        else
          Rails.logger.info "[MarketData::Sync::MarketRegistryJob] ✅ 所有市场已同步,无需注册"
        end

        # 4. 修复损坏的市场键 (在Redis Set中但缺少详细信息)
        broken_market_ids = redis_market_ids.select do |market_id|
          !market_key_valid?(market_id)
        end

        if broken_market_ids.any?
          stats[:fixed_markets] = broken_market_ids.size
          Rails.logger.warn "[MarketData::Sync::MarketRegistryJob] ⚠️ 发现 #{broken_market_ids.size} 个损坏的市场键: #{broken_market_ids.join(', ')}"
          fix_broken_markets(broken_market_ids)
        end

        # 5. 释放数据库连接
        ActiveRecord::Base.connection_pool.release_connection

        Rails.logger.info "[MarketData::Sync::MarketRegistryJob] ✅ 同步完成 - 数据库: #{stats[:db_markets]}, Redis: #{stats[:redis_markets]}, 新增: #{stats[:new_markets]}, 修复: #{stats[:fixed_markets]}"

      rescue StandardError => e
        Rails.logger.error "[MarketData::Sync::MarketRegistryJob] ❌ 同步失败: #{e.message}"
        Rails.logger.error e.backtrace.join("\n")
        raise # 重新抛出异常以触发Sidekiq重试
      end
    end

        private

    # 从数据库获取所有市场ID
        def fetch_db_markets
      Trading::Market.pluck(:market_id).map(&:to_s)
    end

    # 从Redis获取已注册的市场ID
        def fetch_redis_markets
      Sidekiq.redis { |conn| conn.smembers("market_list") }.map(&:to_s)
    end

    # 批量注册新市场到Redis
        def register_markets(market_ids)
      market_ids.each do |market_id|
        register_single_market(market_id)
      end

      Rails.logger.info "[MarketData::Sync::MarketRegistryJob] ✅ 成功注册 #{market_ids.size} 个市场"
    end

    # 注册单个市场到Redis
        def register_single_market(market_id)
      # ��询市场详细信息
      market = Trading::Market.find_by(market_id: market_id)

      unless market
        Rails.logger.warn "[MarketData::Sync::MarketRegistryJob] ⚠️ 市场 #{market_id} 在数据库中不存在,跳过注册"
        return
      end

      redis_key = "orderMatcher:#{market_id}"

      # 设置市场详细信息
      Sidekiq.redis do |conn|
        conn.hset(redis_key, "market_id", market.market_id)
        conn.hset(redis_key, "status", "waiting")
        conn.hset(redis_key, "db_id", market.id.to_s)
        # 添加到市场列表Set
        conn.sadd("market_list", market_id)
      end

      Rails.logger.debug "[MarketData::Sync::MarketRegistryJob] 📝 已注册市场 #{market_id}"
    end

    # 检���市场键是否有效
        def market_key_valid?(market_id)
      redis_key = "orderMatcher:#{market_id}"

      # 检查必需字段是否存在
      Sidekiq.redis do |conn|
        has_market_id = conn.hexists(redis_key, "market_id")
        has_status = conn.hexists(redis_key, "status")
        has_market_id && has_status
      end
    end

    # 修复损坏的市场键
        def fix_broken_markets(market_ids)
      market_ids.each do |market_id|
        redis_key = "orderMatcher:#{market_id}"

        # 删除损坏的键并从Set中移除
        Sidekiq.redis do |conn|
          conn.del(redis_key)
          conn.srem("market_list", market_id)
        end

        # 重新注册
        register_single_market(market_id)

        Rails.logger.info "[MarketData::Sync::MarketRegistryJob] 🔧 已修复市场 #{market_id}"
      end
        end
      end
    end
  end
end
