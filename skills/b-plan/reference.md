# b-plan reference

Compact templates for `b-plan`.

## Saved-plan skeleton

Use durable frontmatter plus checkbox steps:

```markdown
---
slug: <task-slug>
status: draft
created_at: <YYYY-MM-DD>
approved_at: null
approved_by: null
approved_head: null
risk: <trivial | low | medium | high>
touch_points:
  - <path>
---

# <task title>

## Goal
<end state>

## Confirmed decisions
- <decision> - <rationale>

## Assumptions
- <unconfirmed assumption, or omit section>

## Planned touch points
- `<path>` - <change>

## Dependencies
- <real dependency, or omit section>

## Risks
- <risk> - <mitigation>

## Steps
- [ ] **<imperative step title>**
  - Changes: <files or symbols>
  - Why now: <ordering reason>
  - Done when: <verification>

## Verification
- <project command or procedure>

## Rollback
- <real rollback note, or omit section>

## Revisions
- <YYYY-MM-DD> - <delta, only when revised>
```

Add deployment notes or mapping outlines only when they affect execution.

## Quick-plan template

```text
### Plan: <goal>

**Scope:** <files or area>
**Risk:** <trivial | low>

**Steps:**
1. <step> - Done when: <check>
2. <step> - Done when: <check>

**Verification:** <narrowest command or procedure>
```

Promote to a saved plan when the quick plan grows beyond about five steps, touches public/sensitive/release surfaces, or needs durable approval.

## Supersede vs revise

- Revise in place when goal, touch points, and most steps survive.
- Supersede when the goal or approach changes wholesale: set old `status: superseded`, add a revision note, create a new slug, and keep the old plan as audit history.
