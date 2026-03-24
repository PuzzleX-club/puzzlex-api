# frozen_string_literal: true

module Trading
  class SpreadAllocation < ApplicationRecord

    REDEEM_PENDING = 'pending'

    belongs_to :order_fill, class_name: 'Trading::OrderFill'

    scope :for_buyer, ->(address) { where(buyer_address: address.to_s.downcase) }
    scope :for_seller, ->(address) { where(seller_address: address.to_s.downcase) }

    scope :buyer_pending_redeem, -> { where(buyer_redeem_status: REDEEM_PENDING) }
    scope :seller_pending_redeem, -> { where(seller_redeem_status: REDEEM_PENDING) }

    scope :buyer_redeemable, -> { buyer_pending_redeem.where('buyer_rebate_amount > 0') }
    scope :seller_redeemable, -> { seller_pending_redeem.where('seller_bonus_amount > 0') }
    scope :for_claimer, lambda { |address|
      normalized = normalize_address_value(address)
      where('buyer_address = :a OR seller_address = :a', a: normalized)
    }

    # 只能本人领取（同一地址可一次性领取其买家+卖家两部分）
    def claimable_by?(claimer_address:)
      normalized = normalize_address(claimer_address)
      return false if normalized.blank?

      normalized == buyer_address.to_s.downcase || normalized == seller_address.to_s.downcase
    end

    # 返回该地址在当前 allocation 上可领取的金额拆分
    def claim_breakdown_for_claimer(claimer_address:)
      normalized = normalize_address(claimer_address)
      return { buyer_amount: 0, seller_amount: 0, total_amount: 0 } if normalized.blank?

      buyer_amount = if normalized == buyer_address.to_s.downcase && buyer_redeem_status == REDEEM_PENDING
                       buyer_rebate_amount.to_i
                     else
                       0
                     end
      seller_amount = if normalized == seller_address.to_s.downcase && seller_redeem_status == REDEEM_PENDING
                        seller_bonus_amount.to_i
                      else
                        0
                      end

      {
        buyer_amount: buyer_amount,
        seller_amount: seller_amount,
        total_amount: buyer_amount + seller_amount
      }
    end

    private

    def self.normalize_address_value(address)
      value = address.to_s.strip.downcase
      return nil if value.blank?

      value.start_with?('0x') ? value : "0x#{value}"
    end

    def normalize_address(address)
      self.class.normalize_address_value(address)
    end
  end
end
