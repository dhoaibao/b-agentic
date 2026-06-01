## 2. Source of truth and plan lifecycle

### Conflict ladder

Use this order when instructions compete:
1. User's latest explicit instruction.
2. Approved saved plan in `.b-agentic/b-plan/<plan-file-slug>.md`.
3. Approved chat plan.
4. Current repository evidence.
5. Conventional defaults recorded as assumptions.

After `b-plan` approval, the approved plan becomes the execution source of truth for multi-step implementation.

**Saved plans are a local approval cache.** Plans under `.b-agentic/b-plan/` are covered by the `.b-agentic/.gitignore` root guard (see §6) and are intentionally not tracked in version control. They are session-local artifacts — the execution source of truth for the current session, not a shared team record. The staleness gate still applies; use mtime or `approved_at` when `approved_head` is unavailable for drift detection.

If multiple approved saved plans plausibly match the same request, do not choose by filename or slug similarity. Ask the user to pick the plan or approve superseding/merging them before editing.

### Durable plan metadata

New saved plans should start with YAML frontmatter so approval and staleness are durable instead of inferred from chat history:

```yaml
---
slug: <task-slug>
status: draft | approved | in-progress | complete | superseded
created_at: <YYYY-MM-DD>
approved_at: <YYYY-MM-DDTHH:MM:SSZ | null>
approved_by: user | null
approved_head: <git-sha | null>
risk: trivial | low | medium | high
touch_points:
  - <path>
---
```

When the user approves a saved plan, update `status`, `approved_at`, `approved_by`, and `approved_head` in place when the repo has a git HEAD. `approved` and `in-progress` are executable approved states; `draft`, `complete`, and `superseded` require explicit current-chat approval or a plan revision before further edits. Legacy plans without frontmatter may still be executed when the current conversation contains explicit approval; use the approval time from chat for staleness checks and do not rewrite legacy plans solely to add metadata.

Before executing a saved plan, validate that required frontmatter is present when the plan is versioned, `status` is executable or currently approved, `touch_points` names the planned files or areas, and every unchecked step has a `Done when` verification. If validation fails, fix the plan through the revision protocol or hand back to `b-plan`; do not silently improvise.

### Plan staleness gate

A saved plan is stale if any of these are true:
- A file listed under `touch_points` frontmatter or `Planned touch points` has been modified since approval. Prefer checking both committed drift (`git diff --name-only <approved_head>..HEAD -- <touch_points>`) and current working-tree drift (`git diff --name-only <approved_head> -- <touch_points>`) when `approved_head` exists; otherwise use mtime or git history from `approved_at` / current-chat approval time.
- A `Confirmed decision` conflicts with the current repo state.
- The git HEAD has moved past a rebase/merge that touches planned files.

A stale plan must be re-planned, not improvised against.

### Plan revision protocol

When the user asks to revise an approved plan, or `b-implement` discovers the plan is wrong mid-execution:

1. Edit the plan file **in place** — never write `plan-v2.md`.
2. Append a `## Revisions` section if not present, then add one entry: `- YYYY-MM-DD — <one-line delta>`.
3. Re-request approval if the revision touches `Confirmed decisions`, `Planned touch points`, or `Steps`. Cosmetic edits do not need re-approval.
4. After approval, restart from the earliest step affected by the revision.

### Do not invent

Do not invent product behavior, acceptance criteria, compatibility promises, or naming decisions. Ask instead.

### Optional domain docs convention

- When a repo already has `CONTEXT.md` or `CONTEXT-MAP.md`, treat it as the project's glossary and bounded-context map, not as an implementation spec.
- When wording, naming, or user intent is ambiguous, prefer the canonical terms from those files and consult nearby ADRs before inventing new terminology.
- Create or update domain docs only when the active skill explicitly owns that work. Do not create glossary or ADR files as a side effect of ordinary implementation.

---
