## 7. Execution discipline

Define success before non-trivial work. Choose the smallest safe path.

If the user asked only for diagnosis or explanation, stop at confirmed root cause or answer unless they also asked for a fix.

### Scope expansion

When discovery reveals adjacent work, classify it before acting:

- **Required** — necessary to satisfy the approved goal or make verification pass. Include it and mention the expansion in the final report.
- **Blocking decision** — changes behavior, public contracts, migrations, dependencies, or sensitive paths beyond the approved scope. Stop and ask or revise the plan.
- **Follow-up** — useful cleanup, hardening, or unrelated defect. Do not fix opportunistically; report it as a follow-up unless the user expands scope.

Security, data-loss, or production-impacting issues found in touched code may be raised immediately, but still require approval before expanding the edit scope.

### Review checkpoints

- Use `b-review` at coherent checkpoints, not just at the very end, when a slice changes a public or external contract, auth/security/migration boundary, shared route/tool surface, or another milestone broad enough that regressions could hide behind later steps.
- Skip checkpoint review for trivial or purely local steps that do not create a useful review boundary.
- If a checkpoint review is deferred because the tree is still mid-transform or the next step is part of the same tightly coupled verification group, say so explicitly.

### Verification ladder

- Discover baseline commands in this order: explicit plan/user command, project scripts, CI config, repo docs, existing language defaults, then one clarification. Do not invent tooling as verification.
- In monorepos, choose commands and version sources from the closest workspace manifest, lockfile, and CI config to the touched files. If multiple workspaces are plausible, state the chosen workspace or ask when it changes correctness.
- Narrow local check first (touched file diagnostics, single test).
- Broader affected-area check second (module tests, type/build narrowed to changed area).
- Full project check only when scope or risk justifies it (high-risk per §3, or shared contracts).

### Command budget

- Prefer one narrow verification command per fix loop, then one broader command only when risk justifies it.
- Before starting a broad, slow, or repeated suite command, state why the narrow checks are insufficient. If it is likely to exceed the current timeout or materially slow the run, ask before continuing unless the user already requested that exact check.
- When a blocked debug/test run depends on environment differences, report an environment snapshot: command, workspace root, package manager/runtime versions when available, relevant flags/config, and what differs or remains unknown.

### Long-running commands

- Prefer bounded foreground commands with explicit timeouts.
- Starting background jobs, dev servers, containers, emulators, or watch modes requires approval when long-lived or mutating local/shared state.
- If a long-running command is approved, record what was started, how it was stopped, and any remaining process or cleanup action in the final report.

### Iteration cap

Use the class-aware cap before reporting remaining evidence and the blocker. Skills do not restate the numbers.

| Class | Cap |
|---|---|
| Trivial (one file, no exports, behavior preserved) | 2 loops |
| Normal (`b-implement`, `b-refactor`, `b-test`) | 3 loops |
| Debug with confirmed root cause (`b-debug` after Step 3) | 5 loops |

Hit the cap → emit `state: blocked`, `cause: iteration_cap`, remaining evidence, and a proposed new approach or explicit user decision before continuing.

### Transform rollback (shared across `b-implement`, `b-refactor`, `b-debug`)

If a partial edit leaves the tree in a broken state (compile failure, import cycle, half-renamed symbol, mid-move imports) and the next iteration cannot move forward without first restoring a coherent baseline:

1. **Finish forward** in one focused pass when the remaining work to coherence is small and the reference map is already in hand, **or**
2. **Patch-based reverse** of only the edits made in the current step/transform.
3. A file-level restore is only acceptable with explicit user approval, because it can discard unrelated user changes in the same path.
4. Never exit the skill with the tree mid-transform — surface the rollback explicitly to the user in the final report.

Skills reference this rule rather than restating it.

### Cascading failures (shared across `b-implement`, `b-refactor`, `b-test`)

If fixing the current step's failure introduces a new failure in a previously-passing area, treat the cascade as evidence that the plan or step scope is wrong, not as another iteration. After **one** attempted cascade fix that does not restore green, stop. Either:

- Trigger the plan revision protocol (§2),
- Hand off to `b-debug` for root cause, or
- Surface the cascade to the user.

Do not burn the iteration cap chasing cascades.

### Completion contract

A non-trivial run is "done" only when **all** are true:

- Required verification ran (or was explicitly skipped with stated reason).
- Status block emitted (§9).
- Artifacts manifest written when more than one artifact exists (§8).
- Outstanding follow-ups land on an existing report surface — the report's `Follow-up` / `Remaining gaps` section, the status block `notes` field, or the `blockers` field when they block the next skill — not silently dropped.
- The tree is in a coherent state — no mid-transform leftovers (see Transform rollback).
- When `b-debug` was active: all `b-debug-probe` markers removed and verified with `rg --hidden 'b-debug-probe' -- <touched-paths>` returning zero matches.

### Source-side output shaping

Shape large command outputs at the source before they enter chat: use targeted flags, filters, counts, summaries, failing sections, or saved logs. Do not paste full test logs, dependency trees, generated files, lockfiles, or broad search output unless the full content is the evidence.

### Truncated output

If command output is truncated or times out, save the full output under the active runtime's temp scratch path (see §8 for runtime-specific paths) and inspect the failing section instead of guessing.

### Verification provenance

Every non-trivial final report lists evidence used: commands, diagnostics, browser state, sources, and skipped/unavailable checks. If output timed out/truncated, include the saved log path or say no full log exists.

### Verification unavailable

When the expected verification cannot run, do not silently substitute a weaker claim. Classify the reason with skipped-check labels, run the strongest non-mutating lower-tier evidence that still applies, and state what remains unverified. If the missing check is required for safety, public contracts, migrations, auth/security, or production-like writes, stop as `blocked` or `needs-input` instead of reporting completion.

### Skipped-check labels

When a relevant check is skipped, use one of these labels before the reason so downstream skills can read it consistently:

- `not-applicable` — the check does not apply to the touched surface.
- `no-framework` — the repo has no established tool for that check.
- `requires-approval` — the check would mutate dependencies, environments, external state, or sensitive data.
- `tool-unavailable` — the required local/MCP tool is missing or failed after the fallback rules.
- `too-costly` — the check is broader than the risk justifies.
- `time-boxed` — the user or run scope intentionally limited verification time.

### Completion closure

- Before reporting non-trivial execution complete, state final verification status, any remaining cleanup or lingering processes/worktrees/test data/artifacts, and the natural next action (review, commit, PR, merge, keep workspace, or discard it).
- If an isolated workspace or linked worktree was used, say whether it remains active and whether cleanup is still pending. Do not delete branches or worktrees without approval.

### Test data lifecycle

For debug and test runs that create, reuse, or mutate data, record the data mode: none, existing read-only, seeded, namespaced run-created, or external/production-like. Clean up only run-created data when cleanup is safe and approved for the target environment. If cleanup is impossible, unsafe, or unapproved, report the exact residue and owner instead of deleting blindly.

### Environment snapshot

For blocked or non-trivial debug and test runs whose result depends on local setup, record the minimum environment snapshot in the final report or artifact: command or URL, workspace root, runtime/package-manager versions when available, relevant flags/config/env names without secret values, data/auth mode when applicable, and what remains unknown. Do not print secret values.

### Empty-state defaults

When the expected input is missing, do not silently fall back; ask once with a concrete default in mind:
- No git diff → ask which commit, branch, or range to review.
- Changed-code review with untracked files → include them from current contents for current-worktree reviews, or state they are excluded when reviewing an explicit commit/range.
- No approved plan → check if the request meets the small-direct-request threshold (§3); otherwise route to `b-plan`.
- No test framework in the repo → ask before adding one; never introduce a framework as a side effect.
- Browser or DOM verification request → route to `b-browser`; do not add browser or DOM tooling as a side effect (see §10).
- No MCP for the requested bundle → see the fallback ladder (§4) and label the run as `[degraded: <bundle> unavailable]`. When any `[degraded:]` label is emitted, the status block's `notes:` line is required and must name the unavailable bundle and the capability that was degraded or skipped.

### Generated artifact provenance

- When a generated, vendored, minified, snapshot, golden, or lock file is touched, final output must say whether the generator/source command was run, skipped, unavailable, or not applicable.
- If the generator is unavailable and a manual derived-file edit is kept, label it partial evidence and name the follow-up needed to regenerate or verify it.

---
