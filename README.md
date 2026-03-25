# PuzzleX API

[![GitHub Org](https://img.shields.io/badge/GitHub-PuzzleX--club-181717?logo=github&logoColor=white)](https://github.com/PuzzleX-club)
[![X](https://img.shields.io/badge/X-@PuzzleX__club-000000?logo=x&logoColor=white)](https://x.com/PuzzleX_club)
[![Ko-fi](https://img.shields.io/badge/Ko--fi-Support%20PuzzleX-FF5E5B?logo=ko-fi&logoColor=white)](https://ko-fi.com/Q5Q61WM14D)
[![Donate with Crypto](https://img.shields.io/badge/Crypto-USDT%20on%20TRON-26A17B?logo=tether&logoColor=white)](https://nowpayments.io/donation?api_key=60e167ac-c9ce-49b4-9286-67008f10e58d)

Reference backend implementation for the [PuzzleX](https://github.com/PuzzleX-club) protocol — an open NFT trading platform built on [Seaport](https://github.com/ProjectOpenSea/seaport).

Built with **Ruby on Rails 7**, **Sidekiq**, and **PostgreSQL**.

## Connect & Support

- PuzzleX organization: [PuzzleX-club](https://github.com/PuzzleX-club)
- X: [@PuzzleX_club](https://x.com/PuzzleX_club)
- Donate: [Ko-fi](https://ko-fi.com/Q5Q61WM14D) or [Crypto (USDT on TRON)](https://nowpayments.io/donation?api_key=60e167ac-c9ce-49b4-9286-67008f10e58d)
- Donation details: [DONATE.md](https://github.com/PuzzleX-club/.github/blob/main/DONATE.md)
- Contributing: [CONTRIBUTING.md](https://github.com/PuzzleX-club/.github/blob/main/CONTRIBUTING.md)
- Contributor terms: [CLA.md](https://github.com/PuzzleX-club/.github/blob/main/CLA.md)

This repository is intentionally scoped to a **pure JSON API backend**.
Legacy Rails-rendered pages, frontend assets, and browser-side build tooling are not part of the public release surface.

## Features

- **Explorer API** — Item metadata, recipe data, on-chain instance/player/transfer queries
- **Trading API** — Order creation, matching, and settlement via Seaport protocol
- **Metadata Providers** — Pluggable catalog and instance metadata providers
- **Example Mode** — Run with sample data, no blockchain required

## Quick Start (Example Mode)

### Prerequisites

- Ruby 3.x
- PostgreSQL
- Redis

### Steps

```bash
# 1. Install dependencies
bundle install

# 2. Create your environment file
cp .env.example .env

# 3. Setup database
RAILS_ENV=development rails db:create db:migrate

# 4. Start the server in example mode
CATALOG_PROVIDER=example \
INSTANCE_METADATA_PROVIDER=example \
rails server
```

### Optional: start Sidekiq

For basic example-mode API reads, Rails alone is enough. If you want matching,
market-data refresh, or indexer pipelines to run, start Sidekiq separately:

```bash
bundle exec sidekiq
```

### Verify

```bash
# Item detail
curl http://localhost:3000/api/explorer/items/1

# Recipe list
curl http://localhost:3000/api/explorer/recipes
```

## Environment Variables

See `.env.example` for the full list with documentation. Key sections:

| Section | Required | Description |
|---------|----------|-------------|
| Database | Yes | `DATABASE_URL` |
| Redis | Yes | `REDIS_URL` |
| Provider | Yes | `CATALOG_PROVIDER`, `INSTANCE_METADATA_PROVIDER` |
| Blockchain | No (example mode) | Chain ID, RPC, contract addresses |

## Architecture

```
app/
  controllers/        # JSON API endpoints
  models/             # ActiveRecord models
  services/
    metadata/         # Provider architecture
      catalog/        # Item/recipe data providers
      instance_metadata/  # NFT metadata providers
  sidekiq/            # Background jobs
config/
  routes.rb           # API routing
  initializers/       # Provider registration
```

## Background Jobs

Sidekiq jobs are organized by runtime domain:

| Domain | Canonical entrypoints | Responsibility |
|---------|-----------------------|----------------|
| Indexer | `Jobs::Indexer::EventCollectorJob`, `Jobs::Indexer::InstanceMetadataScannerJob` | On-chain event collection and instance metadata fetch pipelines |
| MarketData | `Jobs::MarketData::Broadcast::DispatcherJob` | Broadcast fan-out, generation, sync, and maintenance |
| Matching | `Jobs::Matching::DispatcherJob`, `Jobs::Matching::Worker` | Matching dispatch, execution, timeout, recovery, over-match checks, and failure handling |
| Merkle | `Jobs::Merkle::*` | Merkle generation and consistency guards |

The repository ships a reference [sidekiq.yml](./config/sidekiq.yml). Operators may
override queue subscriptions and process topology in their deployment environment.

### Provider Architecture

PuzzleX API uses a pluggable provider pattern for data sources:

| Provider | Purpose | Implementations |
|----------|---------|-----------------|
| CatalogProvider | Item/recipe static data | `repo_sync`, `example` |
| InstanceMetadataProvider | NFT instance metadata | `api`, `example` |

Set providers via environment variables:

```bash
CATALOG_PROVIDER=example           # or: repo_sync
INSTANCE_METADATA_PROVIDER=example # or: api
```

For the full runtime layout, see [app/sidekiq/README.md](./app/sidekiq/README.md).

## License

[AGPL-3.0-only](./LICENSE)

For commercial licensing options, contact the PuzzleX team.
