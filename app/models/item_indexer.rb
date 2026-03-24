# frozen_string_literal: true

# ItemIndexer — generic namespace for on-chain item indexer models.
#
# This is the canonical application namespace for on-chain indexed NFT
# data. The underlying database tables remain unchanged, but app code
# should only reference ItemIndexer::*.
#
# Usage:
#   ItemIndexer::Item.find_by(id: '42')
#   ItemIndexer::InstanceBalance.where(player: address)
#
module ItemIndexer
end
