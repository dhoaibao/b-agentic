---
name: b-review
description: >
  Pre-PR changed-code review. ALWAYS invoke for "code review", "review before PR", "kiểm tra logic", "what would a reviewer flag", or after implementation is done. Do NOT invoke for UI/design review, plan review, research synthesis review, or repository/skill audit unless the user asks for PR-style code review. Unlike b-test, b-review judges adequacy and risk; it does not primarily write tests.
compatibility: opencode
metadata:
  suite: b-skills
---

# b-review

$ARGUMENTS

Review changed code from a reviewer's perspective before it becomes a PR. Checks logic
correctness, requirements coverage, edge cases, and test adequacy — the things automated
tooling cannot catch.

If `$ARGUMENTS` is provided, treat it as a pointer to the plan file or a description of the original requirements (e.g. `add retry logic to email queue`). Use it as the requirements baseline for Step 2. If `$ARGUMENTS` contains the phrase `skip test adequacy`, skip the test-adequacy and observability sub-checks (Step 5 test block + Step 6 entirely).

## Fast-path threshold

A diff that is **≤50 lines AND ≤2 files** is treated as a small change. The fast-path is referenced from Steps 2, 3, and 6 below to skip requirements-baseline enforcement loops and some expanded checks. Fast-path NEVER skips security checks for new or changed entry points, auth/authz, injection vectors, or sensitive-data handling.

## When to use

- After implementation is done, before committing or opening a PR.
- User says "code review", "review before PR", "kiểm tra logic trước khi push", "what would a reviewer flag".
- Validating that the implementation actually fulfills the original requirements.
- Checking if test coverage is adequate for the behavior that was changed.

## When NOT to use

- Something is broken → use **b-debug**
- write or fix tests → use **b-test**
- Need library API details before writing code → use **b-research**
- UI/design/UX review, plan review, research synthesis review, or repository/skill audit → do not use **b-review** unless the user explicitly asks for PR-style changed-code review.

## Tools required

- `bash` — to read git diff and changed file list.
- `sequentialthinking` — from `sequential-thinking` MCP server — structured review reasoning.
- `check_onboarding_performed`, `onboarding`, `find_symbol`, `get_symbols_overview`, `find_referencing_symbols`, `find_declaration`, `find_implementations`, `get_diagnostics_for_file` — from `serena` MCP server *(preferred for symbol-aware review; use native read/bash search for unsupported file and exact-string operations)*
- `firecrawl_scrape` — from `firecrawl` MCP server *(optional, for fetching issue/ticket URL content when an `**Issue**:` URL is present in the plan file)*
- `resolve-library-id` + `query-docs` — from `context7` MCP server *(optional, for verifying library API calls in changed code)*
- `brave_web_search` — from `brave-search` MCP server *(optional, for CVE/known-vulnerability lookup when a risky security pattern is found)*
- `gitnexus` — from `gitnexus` MCP server *(optional radar for blast-radius, route/API consumer, and changed-flow analysis — only when indexed and fresh)*

Fallbacks follow the global MCP rules. If optional research tools are unavailable, skip enrichment and label the affected review dimension as manual/limited.

Graceful degradation: ✅ Possible — core review works with bash + read. Each MCP adds a specific review dimension; none is strictly required.

## Steps

### Step 1 — Get the diff

Run:
```bash
git diff HEAD
git status --short
```

If the diff output is empty, ask the user — "No uncommitted or staged changes found. Which changes should I review? Provide a commit hash, branch name, or comparison range." Do not silently review `HEAD~1`; `git diff HEAD` already covers staged and unstaged changes relative to `HEAD`.

Extract:
- **Files changed**: list of modified, added, deleted files.
- **Changed lines**: what was added (+) and removed (-).
- **Scope**: how wide is the change?

If `git status --short` shows untracked non-sensitive files that appear related to the change, include them in scope by reading the relevant sections or asking the user if ambiguous. Do not read untracked files that may contain secrets.

If the diff is large (>500 lines changed), ask the user which area to focus on first rather than reviewing everything at once.

Determine fast-path eligibility now and reference it in the rest of the workflow.

---

### Step 2 — Establish requirements baseline

Determine what the code was *supposed* to do.

1. **Check $ARGUMENTS** — if provided:
   - Ends in `.md` → `read` to verify the file exists; if it does, treat as the primary requirements source.
   - Otherwise → treat as a text description of requirements.
2. **Check for plan files** — only if `$ARGUMENTS` is absent. Look for `.opencode/b-plans/*.md` candidates. If exactly one clearly matches the changed scope, read the `## Steps` section and original scope statement. If multiple plan files exist or no candidate clearly matches, ask the user which plan/requirements to use. Do not guess among multiple plans.
3. **Issue enrichment** *(only when a plan file was selected)*: scan the plan header for an `**Issue**:` field.
   - If the value starts with `http`: `firecrawl_scrape` with `url=[value]` and `formats: ["markdown"]`. Trim to 500 words and append to the requirements baseline as: `**Issue context** (from [URL]):\n[scraped content]`. If <200 chars or 403: skip silently and note: "Issue URL requires authentication — using URL as context reference only: [value]."
   - If the value is a ticket ID: display in the review output header as `**Issue reference**: [value]`. No fetch.
   - If absent: skip.
4. **Ask the user** — if neither arguments nor a plan are available: "What was this change supposed to accomplish? What does 'done' look like?" Initial ask, then one re-prompt if vague — two questions maximum.

**Fast-path**: when the diff is fast-path eligible, accept any non-empty requirements baseline (one sentence is sufficient) and skip the vague-response loop below.

**Vague response enforcement** *(non-fast-path only)*: if the user's answer is fewer than 2 sentences or lacks specific behavior or acceptance criteria, ask once more with a concrete example prompt:
> "Please be more specific. For example: 'The retry logic should attempt 3 times with exponential backoff, and log each failure. It should not retry on 4xx errors.' What specific behavior should this code exhibit, and how would you verify it works?"

If still vague or unavailable, continue in **diff-only risk review** mode instead of blocking:
- Set `Requirements baseline` to `unavailable`.
- Mark `Review mode` as `diff-only risk review`.
- Review correctness, obvious regressions, security risk, edge cases, and test gaps visible from the diff.
- Skip strict requirements coverage in Step 4 and report that requirements fulfillment could not be fully assessed.

---

### Step 3 — Logic correctness review

If GitNexus passes the global gate and is relevant to the diff scope, run blast-radius analysis first for broad changed-flow, route/API consumer, or cross-module risk. Then narrow with Serena's symbol-aware read-order:

**Blast-radius analysis**: use `gitnexus detect_changes` or `gitnexus impact` to prioritize deeper review, then confirm findings with `git diff` and Serena reference checks.

If the diff touches an API route, route consumer, or response contract, prefer `gitnexus_api_impact` or `gitnexus_shape_check` before broad graph traversal. If it touches an MCP/RPC tool definition or handler, use `gitnexus_tool_map`.

Stop the GitNexus leg once review priority is clear. Use Serena and the diff as the source of truth for the actual code finding; do not duplicate source inspection in GitNexus.

Initialize Serena project knowledge next: call `check_onboarding_performed`; if onboarding has not been performed, run `onboarding`. Then follow this exact read-order:

1. `find_symbol` on changed names — map them to real symbols.
2. `find_declaration` when the diff highlights a call site, import, or usage more clearly than the owning definition.
3. `find_implementations` when the change touches an interface, abstract method, or polymorphic contract.
4. `find_referencing_symbols` on top changed symbols — understand downstream impact.
5. `get_symbols_overview` on changed files before opening source.
6. Native `read` only for the highest-risk symbol bodies or file sections.
7. Native bash search when the diff changes a shared helper, exported boundary, exact string, config key, or repeated pattern.

**Impact-first review rule**: prioritize review depth on (a) symbols with the broadest references, (b) symbols at service boundaries, and (c) symbols implementing explicit requirements from Step 2. Raw line-count alone should not determine review depth.

When a changed file sits in a typed or compiled language and the diff suggests unresolved breakage, call `get_diagnostics_for_file` on that file before escalating to broader build or test evidence.

Read the changed code and check:

**Control flow**
- Are all branches of conditionals handled? (if/else, switch cases, error paths)
- Are there unreachable branches or always-true conditions?
- Are loops bounded? Can they run forever?

**Data handling**
- Are null/undefined/empty inputs handled?
- Are type coercions or implicit conversions safe?
- Are array/object accesses guarded against out-of-bounds or missing keys?

**Async correctness** *(if applicable)*
- Are all async paths awaited?
- Are errors from async operations caught?
- Are there race conditions between parallel operations?

**Side effects**
- Does the code modify shared state unexpectedly?
- Are there unintended writes to external systems (DB, cache, queue) in non-obvious paths?

**Library API correctness** *(when changed code calls external libraries)*
- Identify third-party library calls in the diff. Skip stdlib calls.
- Pick the **top 2–3 most suspicious calls**: prioritize unfamiliar libraries, calls with complex parameter patterns, anything involving auth, crypto, or serialization.
- For each: `resolve-library-id` + `query-docs` with the specific method to verify signature, parameter order, required fields, and deprecation status.
- Flag wrong parameter order, deprecated method, missing required field, or behavior mismatch.
- Cap at 3 context7 calls per review.

**Security review**

**Always check** (no fast-path exception):
- **Injection vectors** — is dynamic SQL, shell commands, or HTML constructed with unsanitized input? Check every user-facing input path regardless of diff size.
- **New or changed entry points** — auth/authz, input validation, sensitive-data logging/returns, and rate limiting for publicly accessible endpoints/handlers/jobs/consumers.
- **CVE lookup** — if an injection vector or known-risky pattern is found (e.g. `eval`, `exec`, `deserialize`, raw SQL concatenation, `innerHTML`): `brave_web_search` with `"[pattern or library] CVE [year]"`. Cap at 1 search query.

**Additional non-fast-path checks**:
1. **Input validation outside entry points** — is untrusted input sanitized before use in DB queries, filesystem paths, or `eval`/exec calls?
2. **Auth/authz propagation** — do deeper service or middleware changes preserve existing authorization assumptions?
3. **Sensitive data propagation** — are passwords, tokens, or PII exposed through logs, errors, telemetry, or responses?
4. **Abuse controls** — do changed public paths preserve rate limiting, throttling, or quota behavior?

For each issue found: state the file, line range, what the problem is, and what the correct behavior should be.

---

### Step 4 — Requirements coverage check

If Step 2 produced no concrete requirements baseline, skip the coverage table and report:
> Requirements coverage not assessed — no baseline was available. This review is limited to diff-visible correctness and risk.

Otherwise, map each requirement from Step 2 against the changed code:

| Requirement | Covered? | Where |
|---|---|---|
| [Requirement 1] | ✅ / ❌ / ⚠️ Partial | [file:line or "not found"] |

**✅ Covered**: code explicitly implements this behavior
**❌ Missing**: no code implements this requirement
**⚠️ Partial**: partially implemented — describe what's missing

Flag any ❌ or ⚠️ as a blocker before PR.

---

### Step 5 — Edge case and test adequacy check

**Edge cases to check** (based on the type of change):
- Empty input, zero values, negative numbers.
- Maximum/minimum boundary values.
- Concurrent or repeated invocations.
- Failure of downstream dependencies (DB down, API timeout).
- Unexpected input types.

**Test adequacy** *(skip if `skip test adequacy` was passed in $ARGUMENTS)*:
- Does a test exist for each requirement from Step 2?
- Do tests cover the unhappy path (errors, empty results, invalid input)?
- Are tests testing behavior or implementation details?
- Is there a test that would catch a regression if this code was accidentally reverted?

If tests are missing for a requirement or critical edge case: flag as a finding, not just a suggestion.

---

### Step 6 — Observability check *(conditional)*

**Skip entirely if**: `skip test adequacy` was passed; the diff does not add new endpoints, route handlers, background jobs, or queue consumers; or the diff is fast-path eligible **and** does not add/change an entry point.

**When triggered** — check *changed code only* for minimum instrumentation:

1. **Entry-point logging** — at least one structured log call at the handler entry point.
2. **Error capture** — errors caught and logged or re-raised. Flag try/catch/except blocks that swallow errors silently.
3. **Metric emission** — if the new code clearly implies a useful metric, is one emitted? Advisory — flag as suggestion, not a blocker.

Non-blocking gaps go under Suggestions; treat missing observability as a blocker only when a new critical path would otherwise be effectively opaque during failures.

---

### Step 7 — Consolidate findings

**If Steps 3–6 found 3 or more issues**, or there is genuine ambiguity about which issues are blockers vs suggestions: call `sequentialthinking`:
> "Given these review findings [list] and this blocker rubric [correctness, requirement miss, security risk, data loss, regression risk], classify each item into blocker, non-blocking risk, or suggestion; explain why; and give one senior-reviewer question."

**If fewer than 3 findings** or all classify obviously: consolidate inline without sequentialthinking.

Use the output to produce the final report.

---

## Output format

```
### b-review: [task / PR title]

**Diff scope**: [N files, +X -Y] *(fast-path: yes/no)*
**Baseline**: [plan / arguments / user-stated / unavailable]
**Mode**: [requirements-based / diff-only risk review]

#### Findings
- [severity] `[file:line]` — [issue] -> [expected behavior]

#### Coverage / Tests / Observability
- Requirements: [covered / missing / not assessed]
- Tests: [adequate / missing gaps]
- Observability: [skipped / adequate / gaps]

#### Verdict
**[READY FOR PR / NEEDS FIXES]**
```

---

## Rules

- Prefer a requirements baseline. If none is available after a bounded clarification attempt, proceed only as a clearly labeled diff-only risk review and do not claim requirements coverage.
- Blocker = anything that would cause a reviewer to request changes before merge.
- Suggestion = improvement that does not block correctness or requirement fulfillment.
- Do not routinely re-run automated checks (lint, tests) — those are normally the user's responsibility. Run a narrow command only when review confidence depends on runtime/type evidence, and label it as reviewer verification.
- If logic is too complex to understand without running it, say so — do not guess.
- Keep diff scope in mind: a 3-line fix needs a lighter review than a 200-line feature.
- If requirements are not fulfillable with the current implementation, state clearly: "Requirement X is not met — the implementation does Y instead of Z".
