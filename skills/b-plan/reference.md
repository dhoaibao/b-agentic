# b-plan — reference

Long-form templates for `b-plan`. The SKILL.md links here so the main file stays scannable under context pressure.

## Saved-plan skeleton (full mode)

Before using this skeleton, read `../../b-agentic/references/contract/02-source-of-truth.md` and `../../b-agentic/references/contract/08-artifacts.md`. New saved plans include durable frontmatter before the Markdown body. Use the path and slug conventions to save the file with an English `<plan-file-slug>` filename, while frontmatter `slug` stays the canonical `<task-slug>`.

```markdown
---
contract_version: <current-contract-version>
slug: <task-slug>
status: draft
created_at: <YYYY-MM-DD>
approved_at: null
approved_by: null
approved_head: null
risk: <trivial | low | medium | high>
touch_points:
  - <path>
blocked_by:
  - slug: <blocking-task-slug>
    status: <draft | approved | in-progress | complete>
---

# <task title>

## Goal
<one paragraph stating the end state>

## Confirmed decisions
- <decision> — <one-line rationale>

## Assumptions
- <what the plan takes for granted that the user did not explicitly confirm>   (omit the section when there are none; do not silently elide unconfirmed assumptions)

## Planned touch points
- `<path>` — <what changes here>

## Dependencies
- <upstream constraint, feature flag, migration order, external readiness>

## Risks
- <risk> — <mitigation or accepted residual>

## Unknowns
- <open question> — <how it will be resolved or who owns it>

## Steps
- [ ] **<imperative step title>**
  - Changes: <files or symbols>
  - Why now: <ordering reason>
  - Done when: <verification>
...

## Verification
- <project-specific command or procedure>

## Rollback
- <how to revert if Step N fails after merge>   (only when real)

## Revisions
- <YYYY-MM-DD> — <one-line delta>   (added when the plan is revised)
```

Add deployment notes only when they are real: feature flags, migration order, external dependency readiness, or rollback risk.

If the task involves field mapping or protocol translation, add a small mapping outline instead of burying it in prose.

## Quick-plan template (chat mode)

Quick plans stay in chat. Use this minimum shape so quick plans don't drift in form:

```text
### Plan: <one-line goal>

**Scope:** <files or area>
**Risk:** <trivial | low>   (after reading `../../b-agentic/references/contract/03-definitions.md`)

**Steps:**
1. <imperative step> — Done when: <check>
2. <imperative step> — Done when: <check>
3. ...

**Verification:** <narrowest command or procedure>
```

If a quick plan accumulates more than ~5 steps or grows risks/unknowns sections, promote it to full mode and save it under `.b-agentic/b-plan/<plan-file-slug>.md`.

## Supersede vs revise

When an approved plan needs replacement (not just edits):

- **Revise in place** when the goal, touch points, and most steps survive. Read `../../b-agentic/references/contract/02-source-of-truth.md` before applying the revision protocol.
- **Supersede** when the goal itself changed, or the approach is being replaced wholesale:
  1. Set the old plan's `status: superseded` and add a final `## Revisions` entry: `- <date> — superseded by <new-task-slug>`.
  2. Create a new plan with a distinct slug. Reference the superseded plan in the new plan's `Dependencies` or `Goal` section.
  3. Do not delete the superseded plan; it remains audit history.

## Multi-plan dependencies

When Plan B cannot start until Plan A merges:

- Record the dependency in Plan B's frontmatter `blocked_by` array with the blocking plan's `slug` and expected `status` (usually `complete`).
- Do not start `b-implement` on Plan B until every plan in `blocked_by` reports `status: complete` and the touched files have settled.
- If Plan A is still `in-progress` but Plan B has independent steps, scope Plan B to those steps and mark the dependent steps explicitly as "blocked on A."
- If `b-implement` discovers a `blocked_by` plan that is not `complete`, stop with `cause: conflict` and report the blocker.
