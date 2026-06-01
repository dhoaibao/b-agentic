## 7. Execution discipline

Define success before non-trivial work. Choose the smallest safe path. If the user asked only for diagnosis or explanation, stop at the confirmed answer unless they also asked for a fix.

### Scope expansion

Classify adjacent discoveries before acting:

- **Required:** necessary for the approved goal or verification; include it and mention the expansion.
- **Blocking decision:** changes behavior, public contracts, migrations, dependencies, sensitive paths, or risk beyond scope; stop and ask or revise the plan.
- **Follow-up:** useful cleanup or unrelated defect; report it instead of fixing opportunistically.

Security, data-loss, or production-impacting issues in touched code may be raised immediately, but still require approval before expanding edits.

### Verification

- Baseline source order: explicit user/plan command, project scripts, CI config, repo docs, existing language defaults, then one clarification.
- Narrow first: touched-file diagnostics or single focused test.
- Broaden second: affected module tests, typecheck, build, or integration check.
- Full project checks are for high-risk/shared-contract changes or when narrower evidence is insufficient.
- Do not invent tooling as verification, and do not silently substitute a weaker check for a required one.

Before broad, slow, or repeated suites, state why narrower checks are insufficient unless the user already requested that exact check.

### Failure handling

- Iteration caps: trivial local work 2 loops; normal implement/refactor/test 3 loops; debug with confirmed root cause 5 loops. At cap, stop with `state: blocked`, `cause: iteration_cap`, remaining evidence, and a proposed new approach.
- Transform rollback: finish forward when coherence is close; otherwise reverse only current-step edits. File-level restore requires approval. Never exit mid-transform.
- Cascading failures: after one attempted cascade fix that does not restore green, stop and revise the plan, hand off to `b-debug`, or surface the cascade.

### Command and output discipline

- Prefer bounded foreground commands. Long-lived dev servers, watch modes, containers, emulators, or background jobs require approval when mutating or persistent.
- Shape large output at the source with targeted flags, filters, summaries, or saved logs. Do not paste full logs, dependency trees, generated files, or lockfiles unless the full content is evidence.
- If output is truncated or times out, save/inspect the relevant failing section instead of guessing.

### Completion contract

A non-trivial run is done only when:

- Required verification ran, or was explicitly skipped with a labeled reason.
- The tree is coherent; no half-transform remains.
- Generated or derived artifacts report whether the generator/source command was run, skipped, unavailable, or not applicable.
- Follow-ups or remaining gaps are reported on an existing surface.
- The §9 status block is emitted when required.

Skipped-check labels: `not-applicable`, `no-framework`, `requires-approval`, `tool-unavailable`, `too-costly`, `time-boxed`.

Final reports include verification evidence, skipped/unavailable checks, cleanup state, and the natural next action. For debug/test runs that depend on local setup, include the minimum environment snapshot: command or URL, workspace root, relevant runtime/package-manager versions when available, flags/config/env names without secret values, data/auth mode, and unknowns.

---
