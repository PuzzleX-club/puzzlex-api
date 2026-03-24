class Onchain::RawLog < Onchain::ApplicationRecord
  has_many :log_consumptions,
           class_name: "Onchain::LogConsumption",
           foreign_key: :raw_log_id,
           dependent: :delete_all

  scope :pending_for_handler, ->(handler_key) {
    joins(:log_consumptions).where(onchain_log_consumptions: { handler_key: handler_key, status: "pending" })
  }
end
