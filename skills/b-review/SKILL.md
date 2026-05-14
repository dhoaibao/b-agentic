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

Review changed code the way a strong reviewer would: prioritize blockers, verify the diff matches intended behavior, and surface real regression or security risk before PR.

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

## Boundary examples

- **Use default b-review:** "Review my current diff before PR" or `--range=origin/main..HEAD` when the subject is changed code.
- **Use `--repo-audit`:** "Audit the installer and runtime contract" when the request is a reviewer-style pass over a named repository area instead of one diff.

## Tools required

- `bash` — inspect `git diff`, `git status`, `git log`, and narrow verification commands.
- `serena-symbol-toolkit` *(preferred for impact-first code inspection)*
- `gitnexus-radar` *(optional, for broad route/API/tool/shared-flow review risk)*
- `context7-docs` *(optional, for suspicious third-party API usage in the diff)*
- `brave-discovery` + `firecrawl-extraction` *(optional, for focused CVE or risky-pattern lookups; honor `AGENTS.md` §6 privacy gate)*

Fallbacks: `AGENTS.md` §4 MCP fallback ladder. If optional bundles are unavailable, continue with a narrower manual review and label the limitation only when it affects confidence.

Graceful degradation: ✅ Possible — review still works with `bash`, native file tools, and focused source inspection.

## Steps

### Step 1 — Scope the review

1. Read the diff. Default scope is `git diff HEAD` against the working tree. Use `git diff <range>` when `--range=<ref>..<ref>` is present, and run `git log --oneline <range>` to enumerate commits.
   In `--repo-audit` mode, skip diff-first scoping and instead lock the audit surface from the user's request. Prefer the named area first; only expand broader when the request requires it.
2. Run `git status --short` to surface uncommitted changes alongside committed ones.
3. **Empty-state** (`AGENTS.md` §7): if there is no diff and `--repo-audit` is not present, ask which commit, branch, or range to review. Do not silently fall back.
4. If the diff is very large, ask the user which area to prioritize first.
5. Pick **self-review** (`--self` or author = user) or **external review** (`--external` or author ≠ user) per the boundary in `AGENTS.md` §10. Default to **self-review** when unspecified and the working tree is dirty.

### Step 2 — Pick the review depth

Use risk bucket, not raw line count, as the gate:

- **Fast path** — allowed only when **all** of:
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

**Security checklist** (run on changed entry points, sensitive paths, and shared boundaries — never skipped, even on the fast path):
- Correctness against stated behavior.
- Input validation, output encoding, injection risk (SQL, command, template, regex, log).
- Auth/authz changes — who can call this now; is the principal checked?
- Sensitive-data exposure — logs, error messages, telemetry, response shapes.
- Concurrency — race conditions, lock scope, write ordering, retry idempotency.
- Dependency hygiene — new packages, version bumps, transitive risk, license shifts.
- Secret handling — env vars, key rotation paths, files that may now be committed.
- Regex DoS — user-supplied input feeding backtracking patterns.
- Rate limiting and resource bounds for new entry points or queues.
- Error handling — swallowed errors, leaky stack traces, fallback behavior under partial failure.

**Generated and lockfile policy:** for generated files, snapshots, golden files, vendored/minified code, and lockfiles, verify the source change or approved generator/dependency action that produced them. If no source or approved generation step exists, flag the artifact change as suspicious rather than reviewing it as hand-written code.

Use diagnostics or a narrow verification command only when review confidence depends on runtime or typed-language evidence.

### Step 4 — Assess coverage and operability

Skip entirely when `--skip-tests` is present.

1. If a baseline exists, map requirements to the diff; flag missing or partial coverage.
2. Check edge cases and test adequacy for changed behavior.
3. Check observability only for new or changed entry points, handlers, jobs, or consumers.

### Step 5 — Report

1. Findings first, ordered by severity from `AGENTS.md` §3 (BLOCKER / MAJOR / MINOR / NIT).
2. Include **Checked and clean** — risk areas inspected with no finding — so the author sees what scope was actually covered.
3. If there are no findings, say so explicitly and note residual risk or skipped verification.
4. Attach the confidence signal from `AGENTS.md` §3 when review depended on partial evidence.

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
- Always include "Checked and clean" so the author sees what scope was actually reviewed.
- In `--repo-audit` mode, name the audited surface explicitly and avoid implying full-repository coverage unless you actually inspected the full repository.
- In `--repo-audit` mode, use a target-specific checklist and report which checklist was applied.
- Treat lockfile, generated, snapshot, golden, vendored, and minified changes as derived artifacts unless the source or approved generation step is clear.
- For self-review, be harsher on author bias; for external review, be explicit about blocker-vs-style. Concretely:
  - **Self-review** — re-derive intent from the diff alone instead of trusting "I meant to do this"; explicitly question test cases the author skipped, error paths the author treated as "won't happen," and naming the author rationalized late; bias toward MAJOR/BLOCKER over NIT when the author's own confidence may be inflated.
  - **External review** — never suggest stylistic rewrites disguised as findings; clearly separate BLOCKER/MAJOR (must change before merge) from MINOR/NIT (author may decline); give the author the benefit of the doubt on idiomatic choices unless they affect correctness, security, or contract.
- If the logic cannot be confirmed confidently, say so and attach the confidence signal.
