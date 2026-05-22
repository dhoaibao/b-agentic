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

### Node.js / Prisma / TypeORM

- **N+1 queries:** Look for `await` inside loops over query results. Replace with `include`/`select` (Prisma) or `JOIN` (TypeORM/Raw).
- **Missing indexes:** Check query logs for sequential scans on large tables; look for `WHERE`, `ORDER BY`, and `JOIN` columns.
- **Unbounded `findMany`:** Ensure list endpoints use `take`/`skip` or equivalent pagination.
- **JSON serialization of large arrays:** `JSON.stringify` on 10k+ objects blocks the event loop; consider streaming or pagination.
- **Memory leaks in closures:** Event listeners, `setInterval`, or `process.on('uncaughtException')` that are never cleaned up.

### Python / Django / SQLAlchemy

- **N+1 queries:** Look for loops accessing related objects without `select_related` or `prefetch_related` (Django), or `joinedload` (SQLAlchemy).
- **Queryset evaluation:** Chaining `.filter()` without `.only()` or `.defer()` fetches all columns; verify `QuerySet.query` output.
- **Synchronous I/O in async views:** Ensure database calls use async ORM paths (`sync_to_async` or native async) in ASGI contexts.
- **Large response payloads:** Django REST Framework serializers with many nested fields; consider `ListSerializer` optimization or pagination.

### Go

- **Goroutine leaks:** Unbuffered channels with no receiver, or goroutines spawned per request without cancellation.
- **Allocations in hot paths:** `fmt.Sprintf` inside tight loops; pre-allocate slices with `make([]T, 0, estimated)`.
- **Database connection pool exhaustion:** Check `db.SetMaxOpenConns` vs actual concurrent load; look for transactions held open longer than needed.
- **Reflection overhead:** `json.Marshal` of large structs with many interface fields; consider code-generated marshalers.

## Frontend checks

- Look for unnecessary rerenders, repeated data fetching, or oversized lists.
- Check image, script, or component loading on the changed surface.
- Confirm new transitions or observers are bounded and cleaned up.

### React

- **Unnecessary rerenders:** Components receiving new object/array references on every render (inline `{}` or `[]` props); verify with React DevTools Profiler.
- **Missing memoization:** Expensive calculations inside render without `useMemo`; callback props without `useCallback` when passed to memoized children.
- **Large list rendering:** Rendering 1000+ items without virtualization (`react-window`, `react-virtualized`).
- **State colocation:** Global state (Redux/Context) updated frequently causes all consumers to rerender; colocate state to the subtree that needs it.
- **Effect cleanup:** `useEffect` with `addEventListener`, `setInterval`, or subscriptions that lack a cleanup function.

### Vue

- **Unnecessary watchers:** Deep watchers on large objects trigger on every nested mutation; prefer computed properties.
- **v-for without key:** Missing `:key` causes inefficient DOM diffing on list mutations.
- **Large reactive objects:** Converting deeply nested API responses to reactive proxies is expensive; freeze static data with `Object.freeze`.

## Reliability/perf crossover

- Question unbounded retries, polling loops, and cache stampede risks.
- Check timeouts, backoff, and cancellation on external calls.
- Verify batching or caching does not break correctness or freshness guarantees.

### All runtimes

- **Exponential backoff with jitter:** Retries without backoff hammer failing services; ensure at least `Math.random() * delay` jitter.
- **Circuit breaker pattern:** Repeated external call failures should short-circuit for a cooldown period.
- **Request cancellation:** Fetch/XHR/axios requests should be cancellable when the component unmounts or the user navigates away.
- **Cache TTL and invalidation:** Verify that cached data has an explicit TTL and that mutations invalidate the right cache keys.
