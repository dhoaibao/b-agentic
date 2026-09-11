# b-refactor

Run concrete behavior-preserving transforms: rename, extract, move, inline, simplify, or delete.

## When to use

- The user names a specific behavior-preserving transform.
- The target is clear enough to change without product decisions.

## When NOT to use

- The request is vague cleanup or changes behavior -> use **b-plan**.
- The work adds frontend/UI behavior -> use **b-frontend**; other new behavior -> use **b-implement**.
- The work fixes a bug -> use **b-debug**.
- The work is test-only -> use **b-test**.

## Tool guidance

- `bash` - `rtk git status --short`, checks, and modern discovery routed through `rtk` whenever supported.
- `codegraph` - select when a concrete repository-wide impact or dependency-structure question is central to the transform and likely valuable; use an available index for that question and initialize an absent index only for that qualifying question.
- `read`/`edit` - routine file work, prose, comments, and config keys. Prefer native edits.

## Steps

1. Lock the exact target and state the behavior that must remain unchanged.
2. Use read for relevant repo context only when it materially affects the transform.
3. Select CodeGraph [cap: mcp.codegraph] when a concrete repository-wide impact question is central to the transform and likely valuable; use an available index and map that impact. Initialize an absent index only for that qualifying question. Use native search for routine discovery and bash with `rg`/`fdfind` for exports, routes, config keys, docs, and generated consumers.
4. When practical, run the narrowest risk-appropriate check to establish a passing behavioral baseline.
5. Apply the smallest matching transform via Pi native `edit`.
6. Re-check references with native search and rerun the baseline check or equivalent narrow verification.
7. Inspect the diff for unintended behavior changes.

When the refactor target is architectural, use concise design vocabulary: interface, seam, adapter, locality, leverage, shallow abstraction, and deletion test. Stop if the work becomes redesign.

## Output format

Target, impact, changes, verification, and follow-up risk.

## Rules

- Preserve behavior.
- When an edit anchor (oldText) fails to match, re-read the target region and re-anchor the edit from current content; never blind-retry the same anchor or widen context speculatively.
- Use symbol-aware tools when they provide a concrete precision or safety benefit; keep native inspection as the default for routine discovery.
- Ask before broad moves or cascading ecosystem changes when they are an unresolved material user-facing choice. Use `ask_user_question` [cap: package.pi-ask-user-question] with 2–4 concrete options, the recommended option first, and the automatic custom-answer row; if unavailable or noninteractive, ask one focused plain-text question. Do not use the questionnaire for routine updates or no-choice confirmations.
- Stop if redesign or behavior change appears.
