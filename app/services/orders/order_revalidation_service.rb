# frozen_string_literal: true

module Orders
  class OrderRevalidationService
    LOCK_SECONDS_FALLBACK = 30

    def initialize(order, actor: nil, max_attempts: nil, lock_seconds: nil)
      @order = order
      @actor = actor
      config = Rails.configuration.x.order_revalidation
      config_max_attempts = config.is_a?(Hash) ? (config[:max_attempts] || config['max_attempts']) : config&.max_attempts
      config_lock_seconds = config.is_a?(Hash) ? (config[:lock_seconds] || config['lock_seconds']) : config&.lock_seconds

      @max_attempts = max_attempts || config_max_attempts || 3
      @lock_seconds = lock_seconds || config_lock_seconds || LOCK_SECONDS_FALLBACK
      @lock_acquired = false
      @attempts_after = nil
      @status_before = order&.offchain_status
      @status_after = order&.offchain_status
      @validation_passed = false
      @failure_reason = nil
    end

    def call
      return invalid_status_result unless revalidatable_status?

      lock_result = acquire_attempt_lock
      return lock_result unless lock_result[:status] == :ok

      if @status_before == 'validation_failed'
        revalidate_validation_failed
      elsif @status_before == 'over_matched'
        revalidate_over_matched
      end

      @status_after = @order.reload.offchain_status
      finalize_history

      {
        status: :completed,
        message: @validation_passed ? 'revalidation_passed' : 'revalidation_failed',
        data: response_data
      }
    ensure
      release_lock if @lock_acquired
    end

    private

    def revalidatable_status?
      %w[validation_failed over_matched].include?(@order.offchain_status)
    end

    def invalid_status_result
      {
        status: :invalid,
        message: 'order_status_not_revalidatable',
        data: response_data
      }
    end

    def acquire_attempt_lock
      @order.with_lock do
        metadata = normalized_metadata(@order.metadata)
        now = Time.current
        lock_until = parse_time(metadata['revalidation_lock_until'])

        if lock_until && lock_until > now
          @attempts_after = metadata['revalidation_attempts'].to_i
          return locked_result
        end

        attempts = metadata['revalidation_attempts'].to_i
        if attempts >= @max_attempts
          @attempts_after = attempts
          return limit_result
        end

        attempts += 1
        metadata['revalidation_attempts'] = attempts
        metadata['last_revalidate_at'] = now.iso8601
        metadata['revalidation_lock_until'] = (now + @lock_seconds).iso8601
        @order.update!(metadata: metadata)

        @lock_acquired = true
        @attempts_after = attempts
      end

      { status: :ok }
    end

    def release_lock
      @order.with_lock do
        @order.reload
        metadata = normalized_metadata(@order.metadata)
        metadata['revalidation_lock_until'] = nil
        @order.update!(metadata: metadata)
      end
    rescue => e
      Rails.logger.error "[OrderRevalidation] 释放锁失败: #{e.message}"
    end

    def revalidate_validation_failed
      result = Matching::State::OrderPreValidator.new.validate(@order)
      if result[:valid]
        Orders::OrderStatusManager.new(@order).set_offchain_status!(
          'active',
          'revalidated'
        )
        @validation_passed = true
      else
        @failure_reason = result[:reason]
        Orders::OrderStatusManager.new(@order).set_offchain_status!(
          'validation_failed',
          @failure_reason
        )
      end
    end

    def revalidate_over_matched
      result = Matching::OverMatch::Detection.check_order_balance_and_approval(@order)
      if result[:sufficient]
        Matching::OverMatch::Detection.send(:restore_order_from_backup, @order)
        @order.reload
        if @order.offchain_status == 'over_matched'
          Orders::OrderStatusManager.new(@order).set_offchain_status!(
            'active',
            'revalidated'
          )
        end
        @validation_passed = true
      else
        @failure_reason = result[:reason]
      end
    end

    def finalize_history
      @order.with_lock do
        metadata = normalized_metadata(@order.metadata)
        history = metadata['revalidation_history']
        history = [] unless history.is_a?(Array)
        history << {
          attempted_at: Time.current.iso8601,
          result: @validation_passed ? 'passed' : 'failed',
          status_before: @status_before,
          status_after: @status_after,
          reason: @failure_reason
        }
        metadata['revalidation_history'] = history
        @order.update!(metadata: metadata)
      end
    rescue => e
      Rails.logger.error "[OrderRevalidation] 写入历史失败: #{e.message}"
    end

    def response_data
      {
        order_hash: @order.order_hash,
        status_before: @status_before,
        status_after: @status_after,
        validation_passed: @validation_passed,
        failure_reason: @failure_reason,
        remaining_attempts: remaining_attempts,
        max_attempts: @max_attempts,
        locked: false
      }
    end

    def locked_result
      {
        status: :locked,
        message: 'revalidation_in_progress',
        data: response_data.merge(locked: true)
      }
    end

    def limit_result
      {
        status: :limit,
        message: 'revalidation_attempts_exhausted',
        data: response_data
      }
    end

    def remaining_attempts
      attempts = @attempts_after || normalized_metadata(@order.metadata)['revalidation_attempts'].to_i
      remaining = @max_attempts - attempts
      remaining.negative? ? 0 : remaining
    end

    def normalized_metadata(metadata)
      return {} unless metadata.is_a?(Hash)
      metadata.deep_dup
    end

    def parse_time(value)
      return nil if value.blank?
      Time.parse(value.to_s)
    rescue ArgumentError
      nil
    end
  end
end
