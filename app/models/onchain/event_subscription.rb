class Onchain::EventSubscription < Onchain::ApplicationRecord
  validates :handler_key, presence: true, uniqueness: true
  validates :abi_key, presence: true
  validates :addresses, presence: true
  validates :topics, presence: true
  validates :block_window, numericality: { greater_than: 0 }

  def topic0_for(log)
    (log["topics"] || [])[0]&.downcase
  end

  def event_name_for(log)
    topic0_mapping[topic0_for(log)] || topic0_mapping[topic0_for(log)&.delete_prefix("0x")]
  end
end
