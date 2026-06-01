# Performance checklist

Use when `b-debug` or `b-review` touches latency, rendering cost, query volume, bundle size, retries, or hot paths.

## Measure first

- Name the metric, workload, and threshold.
- Capture before/after numbers when possible.
- Prefer profiler, tracing, benchmark, logs, counters, or query plans over intuition.

## Server checks

- N+1 queries or repeated serialization in loops.
- Missing pagination, payload bounds, retry bounds, timeout, backoff, cancellation, or cache invalidation.
- Blocking I/O or expensive computation on request paths.
- DB indexes and connection pool limits on filtered, sorted, joined, or high-concurrency paths.
- Goroutine/task/listener leaks, unbounded background work, and large allocations in hot loops.

## Frontend checks

- Unnecessary rerenders from unstable object/array/callback props.
- Expensive render calculations without memoization.
- Large lists without virtualization.
- Repeated data fetching, polling, observers, subscriptions, timers, or event listeners without cleanup.
- Oversized images, scripts, components, or deeply reactive data.

## Reliability crossover

- Retries use bounded exponential backoff with jitter.
- External failures have timeout/cancellation and, when needed, circuit breaking.
- Caching has explicit TTL and mutations invalidate the right keys.
- Batching/caching preserves correctness and freshness.
