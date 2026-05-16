# Performance checklist

Use this when `b-debug` or `b-review` touches latency, rendering cost, query volume, bundle size, or retry behavior.

## Measure first

- Name the metric that got worse or must stay bounded.
- Capture a before/after number when possible.
- Prefer profiler, tracing, benchmark, or runtime counters over intuition.

## Server-side checks

- Look for N+1 queries and repeated serialization work.
- Check pagination, payload size, and retry bounds on list or fan-out paths.
- Check blocking I/O or expensive computation on hot request paths.

## Frontend checks

- Look for unnecessary rerenders, repeated data fetching, or oversized lists.
- Check image, script, or component loading on the changed surface.
- Confirm new transitions or observers are bounded and cleaned up.

## Reliability/perf crossover

- Question unbounded retries, polling loops, and cache stampede risks.
- Check timeouts, backoff, and cancellation on external calls.
- Verify batching or caching does not break correctness or freshness guarantees.
