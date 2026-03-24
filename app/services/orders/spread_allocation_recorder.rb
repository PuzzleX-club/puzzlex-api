# frozen_string_literal: true

# 基于链上事件真值记录 spread 分配账本
module Orders
  class SpreadAllocationRecorder
    BPS_DENOMINATOR = 10_000

    class << self
      def record_for_match_event!(matched_event:, buy_order:, sell_order:, buy_fills:, sell_fills:)
        return if matched_event.blank? || buy_order.blank? || sell_order.blank?
        return if Trading::SpreadAllocation.exists?(transaction_hash: matched_event.transaction_hash, log_index: matched_event.log_index)

        buy_fulfilled_event = find_order_fulfilled_event(matched_event.transaction_hash, buy_order.order_hash)
        sell_fulfilled_event = find_order_fulfilled_event(matched_event.transaction_hash, sell_order.order_hash)
        return if buy_fulfilled_event.blank? || sell_fulfilled_event.blank?

        buy_payment_by_token = sum_erc20_amounts_by_token(safe_json_array(buy_fulfilled_event.offer))
        sell_payment_by_token = sum_erc20_amounts_by_token(safe_json_array(sell_fulfilled_event.consideration))
        token_address, buy_total = select_primary_token(buy_payment_by_token)
        return if token_address.blank? || buy_total <= 0

        sell_total = sell_payment_by_token[token_address].to_i
        spread_total = buy_total - sell_total
        return if spread_total <= 0

        bps = spread_distribution_bps
        platform_amount = (spread_total * bps[:platform]) / BPS_DENOMINATOR
        remain_after_platform = spread_total - platform_amount
        royalty_amount = (remain_after_platform * bps[:royalty]) / BPS_DENOMINATOR
        remain_after_royalty = remain_after_platform - royalty_amount
        seller_bonus_amount = (remain_after_royalty * bps[:seller]) / BPS_DENOMINATOR
        buyer_rebate_amount = remain_after_royalty - seller_bonus_amount

        order_fill = (sell_fills.first || buy_fills.first)
        return if order_fill.blank?

        market_id = (buy_order.market_id || sell_order.market_id).to_s
        buyer_address = normalize_address(buy_order.offerer || buy_order.parameters&.dig('offerer'))
        seller_address = normalize_address(sell_order.offerer || sell_order.parameters&.dig('offerer'))
        token_address = normalize_address(token_address)
        return if market_id.blank? || buyer_address.blank? || seller_address.blank? || token_address.blank?

        Trading::SpreadAllocation.create!(
          order_fill: order_fill,
          transaction_hash: matched_event.transaction_hash,
          log_index: matched_event.log_index,
          market_id: market_id,
          buyer_address: buyer_address,
          seller_address: seller_address,
          token_address: token_address,
          total_spread: spread_total.to_s,
          platform_amount: platform_amount.to_s,
          royalty_amount: royalty_amount.to_s,
          buyer_rebate_amount: buyer_rebate_amount.to_s,
          seller_bonus_amount: seller_bonus_amount.to_s,
          distribution_config: {
            platform_bps: bps[:platform],
            royalty_bps: bps[:royalty],
            seller_bps: bps[:seller],
            source: 'chain_events'
          }
        )
      rescue => e
        Rails.logger.error("[SpreadAllocationRecorder] 记录 spread allocation 失败: #{e.message}")
      end

      private

      def find_order_fulfilled_event(transaction_hash, order_hash)
        Trading::OrderEvent.find_by(
          event_name: 'OrderFulfilled',
          transaction_hash: transaction_hash,
          order_hash: order_hash
        )
      end

      def safe_json_array(value)
        return value if value.is_a?(Array)
        return [] if value.nil?

        data = JSON.parse(value)
        data.is_a?(Array) ? data : []
      rescue JSON::ParserError
        []
      rescue TypeError
        []
      end

      def sum_erc20_amounts_by_token(items)
        items.each_with_object(Hash.new(0)) do |item, memo|
          next unless item.is_a?(Hash)
          next unless item['itemType'].to_i == 1

          token = normalize_address(item['token'])
          amount = (item['amount'] || item['startAmount'] || item['endAmount']).to_i
          next if token.blank? || amount <= 0

          memo[token] += amount
        end
      end

      def select_primary_token(token_amount_hash)
        token_amount_hash.max_by { |_token, amount| amount } || [nil, 0]
      end

      def spread_distribution_bps
        match_spread_config = Rails.application.config.x.match_spread
        {
          platform: match_spread_config&.platform_bps.to_i.clamp(0, BPS_DENOMINATOR),
          royalty: match_spread_config&.royalty_bps.to_i.clamp(0, BPS_DENOMINATOR),
          seller: match_spread_config&.seller_bps.to_i.clamp(0, BPS_DENOMINATOR)
        }
      end

      def normalize_address(address)
        addr = address.to_s.strip
        return nil if addr.blank?

        addr = "0x#{addr}" unless addr.start_with?('0x')
        addr.downcase
      end
    end
  end
end
