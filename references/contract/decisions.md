## Cross-cutting decisions

Use this for edge cases shared by multiple skills.

### High-risk completion gate

Before claiming completion on auth/authz, security boundaries, migrations, public/external contracts, or irreversible external writes, state the claim, strongest remaining risk, and evidence that makes the claim acceptable.

Developer-tooling public contracts include skill names/frontmatter, CLI flags, MCP tool names or schemas, installer behavior, generated config formats, exported APIs, route shapes, and documented runtime behavior.

### Test versus bug

| Signal | Route |
|---|---|
| Assertion, mock, fixture, setup, snapshot, or test harness drift | `b-test` |
| Failing test reveals product behavior likely wrong in runtime | `b-debug` |
| Intended behavior unclear | `b-plan` or ask for baseline |
| Real browser, live UI, screenshot, visual, session, or e2e evidence needed | `b-browser` |

### Browser boundary

`b-browser` may assess supplied/CI evidence, run existing repo-provided commands, or use `playwright-browser-operator` after safety gates allow it. If no approved evidence path exists, stop with `cause: evidence_gap` or report an accepted follow-up.

Do not add browser or DOM tooling as a side effect. Simulated DOM/component work belongs to `b-test`; real-browser/visual/e2e evidence belongs to `b-browser`.

### Snapshots and goldens

Update snapshots/goldens only after stating intended behavior and citing the source change or product decision. Treat generated, vendored, minified, snapshot, golden, and lock files as derived unless source or approved generation is clear.

### Flakes

Rerun the suspected test up to 2 times in isolation. If it passes some runs and fails others without code changes, mark it `flaky`, capture failing output under the active runtime temp scratch path, and investigate ordering, shared state, async timing, or external time/network dependence before skipping or rewriting.

### Cannot reproduce

When a reported bug cannot be reproduced, report exact repro attempted, environment, observed result, missing input, and next evidence needed. Do not patch speculatively unless the user explicitly asks for a defensive change.

---
