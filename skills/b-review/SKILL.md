---
name: b-review
description: >
  Pre-PR changed-code review. ALWAYS invoke after implementation is done and
  the user wants a reviewer-style read of a diff, commit range, or explicitly
  requested repository audit. Do NOT invoke for UI/design review, plan review,
  or research synthesis review. Unlike b-test, b-review judges adequacy and
  risk; it does not primarily write tests.
compatibility: opencode
metadata:
  suite: b-skills
---

# b-review

$ARGUMENTS

Review changed code: prioritize blockers, verify intent, and surface regression/security risk before PR.

If `$ARGUMENTS` is provided, treat it as the requirements pointer or summary.

**Flags** (explicit tokens in `$ARGUMENTS`):
- `--skip-tests` — skip the test-adequacy and observability assessment.
- `--baseline=<path|url>` — point at a plan, ticket, or requirements doc to ground the review.
- `--range=<ref>..<ref>` — review a specific commit range instead of `HEAD`. Defaults to `HEAD` against the working tree.
- `--repo-audit` — audit an explicitly requested repository area or suite slice rather than a diff.
- `--self` — author is the same person asking for the review; bias for author blind spots.
- `--external` — author is someone else; bias for blocker-vs-style clarity.

## When to use

- The user wants a pre-PR or pre-commit changed-code review.
- The user explicitly wants a reviewer-style repository or maintainer audit.
- The goal is to find correctness, regression, security, edge-case, or coverage risks.
- The implementation is done and needs reviewer-style scrutiny.

## When NOT to use

- Something is broken and needs root-cause tracing → use **b-debug**.
- The task is writing or fixing tests → use **b-test**.
- The task is external docs or API lookup → use **b-research**.
- The request is plan review, UX critique, or research synthesis review rather than code-review-style risk assessment.

## Tools required

- `bash` — inspect `git diff`, `git status`, `git log`, and narrow verification commands.
- `serena-symbol-toolkit` *(preferred for impact-first code inspection)*
- `gitnexus-radar` *(optional, for broad route/API/tool/shared-flow review risk)*
- `context7-docs` *(optional, for suspicious third-party API usage in the diff)*
- `brave-discovery` + `firecrawl-extraction` *(optional, for focused CVE or risky-pattern lookups; honor `AGENTS.md` §6 privacy gate)*

Fallbacks: `AGENTS.md` §4. If optional bundles fail, continue narrower and label only when confidence is affected. Graceful degradation: ✅ Possible with `bash`, native tools, and focused source reads.

## Steps

### Step 1 — Scope the review

1. Read the diff. Default scope is `git diff HEAD` against the working tree. Use `git diff <range>` when `--range=<ref>..<ref>` is present, and run `git log --oneline <range>` to enumerate commits.
   In `--repo-audit` mode, skip diff-first scoping and instead lock the audit surface from the user's request. Prefer the named area first; only expand broader when the request requires it.
2. Run `git status --short` to surface uncommitted changes alongside committed ones.
3. **Empty-state** (`AGENTS.md` §7): if there is no diff and `--repo-audit` is not present, ask which commit, branch, or range to review. Do not silently fall back.
4. If the diff is very large, ask the user which area to prioritize first.
5. **WIP / in-progress branches.** When the branch contains WIP commits (commit messages starting with `WIP`, `wip:`, `fixup!`, `squash!`) or uncommitted dirty state on top of recent commits, default to reviewing the **cumulative diff** rather than the latest commit alone. Resolve the comparison base in this order, stopping at the first that succeeds:
   1. `--range=<base>..<head>` if the user supplied it.
   2. The upstream tracking branch: `git rev-parse --abbrev-ref @{upstream}` → use `git merge-base @{upstream} HEAD`.
   3. The repo's default branch as reported by `git symbolic-ref refs/remotes/origin/HEAD` (typically `origin/main` or `origin/master`) → use `git merge-base <default> HEAD`.
   4. If none of the above resolves (detached HEAD, no upstream, no remote default), fall back to **working-tree diff** (`git diff HEAD`) and state in the report's `Scope` that no branch base was discoverable.

   State the chosen base (or its absence) explicitly in `Scope`. Switch to per-commit review only when the user asks for it.
6. Pick **self-review** (`--self` or author = user) or **external review** (`--external` or author ≠ user) per the boundary in `AGENTS.md` §10. Default to **self-review** when unspecified and the working tree is dirty.

### Step 2 — Pick the review depth

Use risk bucket, not raw line count, as the gate:

- **Fast path** — only when **all** hold:
  - All changes are confined to a single non-sensitive module or feature area.
  - No auth, authz, billing, secrets, crypto, or migration files touched.
  - No public contract changed (exported API, route, CLI flag, schema).
  - No new external dependency.

  On the fast path, run the security checklist on changed entry points and shared boundaries only — but still run it.
- **Standard review** — anything else. Run the full Step 3 inspection.

`--repo-audit` always uses the standard path.

Line/file count alone never decides the path; a 5-line change touching auth is not a fast-path candidate.

### Step 3 — Establish baseline and inspect risk

**Baseline:**
1. Use `$ARGUMENTS`, `--baseline=…`, an approved plan, or short user clarification to define what the change was supposed to do.
2. If a selected plan references an issue URL, optionally extract it via `firecrawl-extraction` for context.
3. If no concrete baseline is available after bounded clarification, continue in **diff-only risk review** mode or **repo-audit risk review** mode. In those modes, do not claim requirements coverage; only flag risks, regressions, and security findings against best-practice expectations and the security checklist.

**Inspect in impact-first order:**
1. Changed symbols with the broadest references.
2. Service boundaries, route handlers, tool handlers.
3. Code that claims to satisfy explicit requirements.

In `--repo-audit` mode, start with the highest-risk shared surfaces in the requested area: runtime contracts, install/update entry points, validators, route/tool boundaries, and the most reused rules before lower-risk docs.

Use a surface-specific checklist when the audit target implies one: installer/update paths, runtime contracts, validators, route/tool boundaries, dependency/lockfile changes, generated artifacts, or security-sensitive rules. Keep the checklist short and name it in the report so `--repo-audit` does not read like a generic skim.

Optionally use `gitnexus-radar` once when the diff is graph-shaped or contract-heavy. Initialize Serena per `AGENTS.md` §4 only when symbol-aware inspection adds value.

**Security checklist** (run on changed entry points, sensitive paths, and shared boundaries, even on fast path): correctness, validation/encoding/injection, auth/authz, sensitive data, concurrency/idempotency, dependencies, secrets, regex DoS, resource bounds, error handling.

For auth/authz, security boundaries, migrations, public or external contracts, or irreversible external writes, run the high-risk challenge gate from `AGENTS.md` §10 before calling the area clean.

If a finding or a clean judgment depends on framework, library, or vendor API semantics, cite the authoritative source in that finding or clean note instead of relying on memory.

**Generated and lockfile policy:** for generated files, snapshots, golden files, vendored/minified code, and lockfiles, verify the source change or approved generator/dependency action that produced them. If no source or approved generation step exists, flag the artifact change as suspicious rather than reviewing it as hand-written code.

Use diagnostics or a narrow verification command only when review confidence depends on runtime or typed-language evidence.

### Step 4 — Assess coverage and operability

Skip entirely when `--skip-tests` is present.

1. If a baseline exists, map requirements to the diff; flag missing or partial coverage.
2. Check edge cases and test adequacy for changed behavior.
3. Check observability only for new or changed entry points, handlers, jobs, or consumers.

### Step 5 — Report

1. Findings first, ordered by severity from `AGENTS.md` §3 (BLOCKER / MAJOR / MINOR / NIT).
2. Include **Checked and clean** — risk areas inspected with no finding — so the author sees what scope was actually covered. Cap at **5 entries**, highest-risk first; do not pad with low-risk inspections.
3. If there are no findings, say so explicitly and note residual risk or skipped verification.
4. Attach the confidence signal from `AGENTS.md` §3 when review depended on partial evidence.

**Research escalation.** If the review requires external knowledge to judge correctness (suspicious third-party API usage, unfamiliar library behavior, CVE plausibility), do **not** drift into open-ended research inline. Either resolve it with a single `context7-docs` lookup or emit a handoff envelope to **b-research** with the specific question and resume the review with the answer in hand.

Close with the skill-exit status block (`AGENTS.md` §9).

## Output format

```text
### b-review: [task or diff]

**Scope:** [files / commits / range]
**Mode:** [self-review / external review] · [requirements-based / diff-only / repo-audit]
**Path:** [fast / standard]
**Baseline:** [plan / arguments / user-stated / unavailable]
**Flags:** [--skip-tests / --range / --repo-audit / ...]

#### Findings
- **BLOCKER** `[path:line]` — [issue] → [expected behavior]
- **MAJOR** `[path:line]` — [issue] → [expected behavior]
- **MINOR** `[path:line]` — [issue]
- **NIT** `[path:line]` — [suggestion]

#### Checked and clean
- [risk area inspected] — [why no finding]

#### Coverage / Tests / Observability
- Requirements: [covered / missing / not assessed]
- Tests: [adequate / gaps / skipped]
- Observability: [adequate / gaps / skipped]

#### Verdict
**[READY FOR PR / NEEDS FIXES]**
```

(Confidence line attached when evidence is partial.)

## Rules

- Findings come first; summaries are secondary.
- Do not claim requirements coverage when no baseline exists.
- Do not run broad automated checks by default; use only the narrow evidence needed.
- Security checklist items are never skipped for changed entry points, sensitive paths, or shared boundaries — even on the fast path.
- The fast path is gated by **risk bucket**, not by line/file count. Auth/security/migration/contract touches always force standard review.
- Always include "Checked and clean" so the author sees what scope was actually reviewed. Cap at 5 entries, highest-risk first.
- In `--repo-audit` mode, name the audited surface explicitly and avoid implying full-repository coverage unless you actually inspected the full repository.
- In `--repo-audit` mode, use a target-specific checklist and report which checklist was applied.
- Treat lockfile, generated, snapshot, golden, vendored, and minified changes as derived artifacts unless the source or approved generation step is clear.
- For self-review, be harsher on author bias; for external review, be explicit about blocker-vs-style. Concretely:
  - **Self-review** — re-derive intent from diff; question skipped tests, "won't happen" error paths, and late naming; bias toward real MAJOR/BLOCKER risk.
  - **External review** — do not disguise style as findings; separate must-fix from optional issues; defer idiom unless correctness/security/contract is affected.
- If the logic cannot be confirmed confidently, say so and attach the confidence signal.

## Reference pointers

- `references/security-checklist.md` (installed under `~/.config/opencode/references/b-skills/`) — use when the diff touches auth, untrusted input, sensitive data, file uploads, webhooks, or external integrations.
- `references/performance-checklist.md` (installed under `~/.config/opencode/references/b-skills/`) — use when the change touches hot paths, query volume, rendering loops, list endpoints, or retry behavior.

## Common rationalizations

- "The tests pass, so it's probably fine." → Tests do not replace contract, security, or operability review.
- "The diff is tiny." → Risk bucket, not line count, decides the review depth.
- "I'll phrase this softly because it might be okay." → Severity should match the actual ship risk, not reviewer comfort.
