class Onchain::LogConsumption < Onchain::ApplicationRecord
  belongs_to :raw_log, class_name: "Onchain::RawLog"

  STATUSES = %w[pending success failed].freeze

  validates :status, inclusion: { in: STATUSES }
  validates :handler_key, presence: true
end
