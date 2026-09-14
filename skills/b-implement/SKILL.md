---
name: b-implement
description: >
  Execute approved or scoped non-UI work safely after b-plan approval,
  when a user gives a small direct request or an approved plan. Applies
  the next small step, verifies it, and hands back to planning or research
  instead of guessing when new ambiguity appears. Frontend/UI code—pages,
  layouts, components, styling, responsive behavior, interactions, or
  visual refreshes—belongs to b-frontend instead. Unlike b-plan,
  b-implement changes code. Routing signals: implement, make the change,
  apply the plan, code the fix, finish the implementation, build the
  feature.
---

<!-- Generated from skills/registry.yaml and skills/b-implement/prompt.md. Edit those sources, not this file. -->

# b-implement

Make the scoped non-UI change in the smallest coherent step after an approved plan or clear direct request.

## When to use

- The user approved a plan or gave a small direct request.
- The next action is a scoped non-UI code or repository change.

## When NOT to use

- Scope or behavior is unclear -> use **b-plan**.
- Frontend/UI code -> use **b-frontend**.
- A named behavior-preserving transform -> use **b-refactor**.
- Test-only work -> use **b-test**.
- An unknown runtime failure -> use **b-debug**.

## Tool guidance

- Use Pi native file tools by default and native tools or local search for routine discovery. Select CodeGraph only when a repository-wide architecture, impact, or affected-test question is central. Use supplied compacted observational-memory ids rather than guessing.

## Steps

1. Resolve the approved plan or direct request, run `rtk git status --short`, and preserve unrelated changes.
2. Before edits, consult applicable project standards, architecture boundaries, and relevant failure modes. State affected paths, invariants, observable success criteria, and relevant quality constraints. Use repository evidence; select CodeGraph only for a concrete central repository-wide question. If a material behavior or external fact is missing, stop and ask the user one focused question about the decision, target, or source/version needed. Wait for the answer and re-evaluate before handing off; do not ask multiple independent blocker questions at once. Once clarified, route remaining material framework/API best-practice uncertainty to targeted **b-research**.
3. Ask the user directly with `ask_user_question` only for material unresolved choices or blockers. Group related questions up to four; address independent blockers in priority order and wait for each answer. Do not relay normal clarification through an architect.
4. Make the smallest coherent edit with native tools, matching the target module's local style. Remove imports/helpers made unused by it, but retain unrelated pre-existing dead code.
5. Run the narrowest useful verification. If an unambiguous in-scope defect causes failure, correct it and rerun until required verification passes. If failure reveals ambiguity, scope drift, or an unrelated issue, stop and ask or route rather than guessing. Inspect explicit non-protected changed paths.
6. When the scoped task is complete and required checks pass, report the changed paths, verification, acceptance coverage, gaps, and risk. In the explicit executor role, every completed Executor-owned task that leaves a tracked or relevant untracked/derived worktree candidate must freeze that candidate and complete the shared explicit executor-role profile's independent **b-review** handoff before any final response. No-change tasks, including PR prose, do not require changed-code review; standalone **Off** mode does not initiate intercom review.
7. If the active executor role initiates a handoff or review, do not edit while it is pending. Use exactly one blocking Intercom `ask` for `b-review` to the sole same-CWD peer and report a coordination gap rather than a normal final result if no valid Architect handoff is possible. A changed snapshot, skipped/failed required check, missing baseline, wrong architect, `NEEDS FIXES`, or unaccepted follow-up blocks shipping. For delegated `NEEDS FIXES`, correct only unambiguous in-scope findings, rerun the required checks, and let the executor-role profile send a fresh snapshot and review request; stop and ask or route when a finding reveals ambiguity or scope drift. No review automatically commits or pushes.

## Output format

Changes, verification, acceptance coverage, and deviations or gaps. For a changed candidate in the explicit executor role, its shared profile requires the **b-review** handoff and pause before a final response; standalone **Off** mode remains solo.

## Rules

- Stay within approved scope and use the smallest evidence-backed fit.
- Roles govern prompts, not tools; shared approval policy remains authoritative.
- Automatic review handoffs are mandatory for changed candidates in the explicit executor-role profile; standalone **Off** mode and no-change outputs must not initiate intercom review.
- When the executor-role profile delegates **NEEDS FIXES**, correct only unambiguous in-scope findings, rerun checks, and let that profile request a fresh review; stop for ambiguity or scope drift.
- Same-day changelog maintenance is required only when preparing a user-authorized commit. Include it in the reviewed candidate or reopen review.
- Never claim shipping readiness when required verification or the independent review gate is absent.
