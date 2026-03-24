# frozen_string_literal: true

module Trading
  class MarketSummary < ApplicationRecord

    validates :market_id, presence: true
  end
end
