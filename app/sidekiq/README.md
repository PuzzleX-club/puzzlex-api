# Sidekiq Background Jobs

This directory contains the background job runtime used by `puzzlex-api`.

## Layout

```text
app/sidekiq/
├── concerns/      # Shared Sidekiq helpers
├── jobs/
│   ├── indexer/
│   ├── market_data/
│   ├── matching/
│   ├── merkle/
│   └── orders/
└── strategies/    # Market-data scheduling strategies
```

## Runtime Model

- `config/sidekiq.yml` defines scheduler entries, queue names, and per-environment Redis settings.
- `sidekiq-scheduler` triggers cron-based jobs from the `:scheduler:` section.
- Runtime code uses `perform_async` / `perform_in` for fan-out and follow-up work.
- Leader-only jobs guard execution through `Sidekiq::Election::Service.leader?`.

## Job Domains

- `jobs/indexer` — on-chain event collection, event consumption, and instance metadata scanning
- `jobs/market_data/broadcast` — market-data broadcast dispatch and execution
- `jobs/market_data/generation` — K line and market aggregate generation
- `jobs/market_data/sync` — registry and summary cache sync
- `jobs/market_data/maintenance` — summary refresh and ensure jobs
- `jobs/matching` — dispatch, worker execution, timeout, recovery, over-match detection, and failure handling
- `jobs/merkle` — Merkle generation and consistency guards
- `jobs/orders` — order event and depth broadcast jobs

## Operational Notes

- `EventCollectorJob` is the canonical on-chain collection entrypoint.
- `Jobs::MarketData::Broadcast::DispatcherJob` is the canonical market-data broadcast scheduler entrypoint.
- `Jobs::Matching::DispatcherJob` is the canonical matching scheduler entrypoint, and `Jobs::Matching::Worker` is the execution worker entrypoint.
- Matching and market-data jobs still use a mix of leader-gated dispatch and queue fan-out; keep queue topology aligned with your deployment model.
- Queue topology is deployment-specific. This repository ships a reference `sidekiq.yml`, but operators may override queue subscriptions at process startup.

## Quick Checks

- Inspect queues:
  `Sidekiq::Queue.all.map { |q| [q.name, q.size] }`
- Inspect scheduled jobs:
  `Sidekiq.get_schedule.keys`
- Run Zeitwerk verification:
  `./bin/be rails zeitwerk:check`
- Run Sidekiq-focused specs:
  `./bin/be rspec spec/sidekiq`
