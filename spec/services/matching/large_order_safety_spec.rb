require 'rails_helper'

RSpec.describe Matching::Engine, type: :service do
  let(:market_id) { "test_market_safety" }
  let(:strategy) { Matching::Engine.new(market_id) }

  before do
    # 使用 ServiceTestHelpers 提供的 stub 方法
    stub_redis
    stub_action_cable
    stub_sidekiq_workers
  end

  describe '大订单安全处理机制' do
    context '卖单总量不足检查' do
      it '当买单数量超过卖单总量时应该立即返回失败' do
        # 卖单总量只有100个
        asks = [
          [100.0, 50, "ask1", 123456], 
          [101.0, 30, "ask2", 123456],
          [102.0, 20, "ask3", 123456]
        ]
        
        # 买单要150个，超过总量100个
        target_qty = 150
        
        result = strategy.send(:find_optimal_combination_dp, target_qty, asks)
        
        expect(result[:match_completed]).to be false
        expect(result[:current_orders]).to be_empty
        expect(result[:remaining_qty]).to eq(150)
      end
      
      it '当买单数量等于卖单总量时应该能正常处理' do
        asks = [
          [100.0, 50, "ask1", 123456], 
          [101.0, 30, "ask2", 123456],
          [102.0, 20, "ask3", 123456]
        ]
        
        target_qty = 100  # 正好等于总量
        
        result = strategy.send(:find_optimal_combination_dp, target_qty, asks)
        
        # 应该能找到匹配（全选）
        expect(result[:match_completed]).to be true
        expect(result[:current_orders].length).to eq(3)
      end
    end

    context 'DP算法数组大小限制' do
      it '超过10000应该降级到递归算法' do
        # 创建足够的卖单
        asks = (1..100).map { |i| [100.0, 200, "ask#{i}", 123456] }
        
        target_qty = 15000  # 超过10000的限制
        
        # Mock递归算法避免实际执行大量计算
        allow(strategy).to receive(:find_best_ask_combination_legacy).and_return({
          match_completed: false,
          current_orders: []
        })
        
        result = strategy.send(:find_optimal_combination_dp, target_qty, asks)
        
        # 验证确实调用了递归算法
        expect(strategy).to have_received(:find_best_ask_combination_legacy)
          .with(15000, asks, 0, [], 0)
      end
    end

    context '内存使用预估检查' do
      it '预估内存超过100MB应该降级到递归算法' do
        # 创建足够的卖单
        asks = (1..100).map { |i| [100.0, 100000, "ask#{i}", 123456] }
        
        # 计算会触发100MB限制的数量：100MB = 100 * 1024 * 1024 / (2 * 8) = 6553600
        target_qty = 7000000  # 预估内存约 7000000 * 2 * 8 / 1024 / 1024 = 107MB
        
        # Mock递归算法
        allow(strategy).to receive(:find_best_ask_combination_legacy).and_return({
          match_completed: false,
          current_orders: []
        })
        
        result = strategy.send(:find_optimal_combination_dp, target_qty, asks)
        
        # 验证确实调用了递归算法
        expect(strategy).to have_received(:find_best_ask_combination_legacy)
          .with(7000000, asks, 0, [], 0)
      end
    end

    context '递归算法安全限制' do
      it '递归深度超过100应该终止递归' do
        asks = [
          [100.0, 1, "ask1", 123456],
          [101.0, 1, "ask2", 123456],
          [102.0, 1, "ask3", 123456]
        ]
        
        target_qty = 2
        
        # 强制触发深度限制（通过直接调用深度101的递归，因为限制是depth > 100）
        result = strategy.send(:find_best_ask_combination_legacy, target_qty, asks, 0, [], 101)
        
        expect(result[:match_completed]).to be false
        expect(result[:current_orders]).to be_empty
      end
      
      it '正常递归深度应该能正常工作' do
        asks = [
          [100.0, 1, "ask1", 123456],
          [101.0, 1, "ask2", 123456]
        ]
        
        target_qty = 2
        
        result = strategy.send(:find_best_ask_combination_legacy, target_qty, asks, 0, [], 0)
        
        expect(result[:match_completed]).to be true
        expect(result[:current_orders].length).to eq(2)
      end
    end

    context '递归算法精确匹配优化' do
      it '应该优先选择精确匹配的订单' do
        asks = [
          [100.0, 5, "ask1", 123456],
          [99.0, 10, "exact_match", 123456],  # 精确匹配
          [101.0, 3, "ask3", 123456],
          [98.0, 7, "ask4", 123456]
        ]
        
        target_qty = 10
        
        result = strategy.send(:find_best_ask_combination_legacy, target_qty, asks, 0, [], 0)
        
        expect(result[:match_completed]).to be true
        expect(result[:current_orders]).to eq(["exact_match"])  # 应该优先选择精确匹配
      end
    end

    context '异常处理和降级机制' do
      it 'DP算法出现异常时应该降级到递归算法' do
        asks = [
          [100.0, 50, "ask1", 123456],
          [101.0, 30, "ask2", 123456]
        ]

        target_qty = 80

        # Mock ExactFillSolver 抛出异常（模拟运行时错误）
        # 注意：不能用 NoMemoryError，它继承自 Exception 而非 StandardError，
        # rescue => e 无法捕获，会导致 RSpec 进程崩溃
        solver_double = instance_double(Matching::Selection::ExactFillSolver)
        allow(Matching::Selection::ExactFillSolver).to receive(:new).and_return(solver_double)
        allow(solver_double).to receive(:solve).and_raise(RuntimeError.new("内存不足"))

        # Mock递归算法
        allow(strategy).to receive(:find_best_ask_combination_legacy).and_return({
          match_completed: true,
          current_orders: ["ask1", "ask2"]
        })

        result = strategy.send(:find_optimal_combination_dp, target_qty, asks)

        # 验证确实调用了递归算法作为降级
        expect(strategy).to have_received(:find_best_ask_combination_legacy)
          .with(80, asks, 0, [], 0)

        expect(result[:match_completed]).to be true
      end
    end

    context '性能边界测试' do
      it '9999数量应该使用DP算法' do
        asks = (1..100).map { |i| [100.0, 150, "ask#{i}", 123456] }
        target_qty = 9999  # 刚好在限制内
        
        # 不应该调用递归算法
        allow(strategy).to receive(:find_best_ask_combination_legacy)
        
        result = strategy.send(:find_optimal_combination_dp, target_qty, asks)
        
        expect(strategy).not_to have_received(:find_best_ask_combination_legacy)
      end
      
      it '10001数量应该降级到递归算法' do
        asks = (1..60).map { |i| [100.0, 200, "ask#{i}", 123456] }  # 总量 60*200=12000 > 10001
        target_qty = 10001  # 超过限制
        
        # Mock递归算法
        allow(strategy).to receive(:find_best_ask_combination_legacy).and_return({
          match_completed: false,
          current_orders: []
        })
        
        result = strategy.send(:find_optimal_combination_dp, target_qty, asks)
        
        expect(strategy).to have_received(:find_best_ask_combination_legacy)
      end
    end
  end

  describe '日志记录验证' do
    before do
      allow(Rails.logger).to receive(:warn)
      allow(Rails.logger).to receive(:info)
      allow(Rails.logger).to receive(:error)
    end

    it '应该记录安全检查的警告日志' do
      # 卖单总量(50)小于目标(15000)，触发总量不足警告
      asks = [[100.0, 50, "ask1", 123456]]
      target_qty = 15000

      strategy.send(:find_optimal_combination_dp, target_qty, asks)

      expect(Rails.logger).to have_received(:warn).with(match(/买单数量.*超过.*卖单总量/))
    end

    it '应该记录内存预估信息' do
      asks = [[100.0, 100, "ask1", 123456]]
      target_qty = 50

      strategy.send(:find_optimal_combination_dp, target_qty, asks)

      expect(Rails.logger).to have_received(:info).with(match(/预估内存.*MB/))
    end
  end
end 