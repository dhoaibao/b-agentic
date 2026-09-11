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

- Use native file tools by default and native tools or local search for routine discovery. Select CodeGraph [cap: mcp.codegraph] only when a repository-wide architecture, impact, or affected-test question is central. Use supplied compacted observational-memory ids rather than guessing.

## Steps

1. Resolve the approved plan or direct request, run `rtk git status --short`, and preserve unrelated changes.
2. Before edits, consult applicable project standards, architecture boundaries, and relevant failure modes. State affected paths, invariants, observable success criteria, and relevant quality constraints. Use repository evidence; select CodeGraph only for a concrete central repository-wide question. If a material behavior or external fact is missing, stop and ask the user one focused question about the decision, target, or source/version needed. Wait for the answer and re-evaluate before handing off; do not ask multiple independent blocker questions at once. Once clarified, route remaining material framework/API best-practice uncertainty to targeted **b-research**.
3. Ask the user directly with `ask_user_question` [cap: package.pi-ask-user-question] only for material unresolved choices or blockers; if unavailable or noninteractive, ask one focused plain-text question. Group related questions up to four; address independent blockers in priority order and wait for each answer.
4. Make the smallest coherent edit with native tools, matching the target module's local style. Remove imports/helpers made unused by it, but retain unrelated pre-existing dead code.
5. Run the narrowest useful verification. If an unambiguous in-scope defect causes failure, correct it and rerun until required verification passes. If failure reveals ambiguity, scope drift, or an unrelated issue, stop and ask or route rather than guessing. Inspect explicit non-protected changed paths.
6. When the scoped task is complete and required checks pass, report the changed paths, verification, acceptance coverage, gaps, and risk. Do not initiate an automatic review handoff; if the user requires **b-review** first, stop and let the user request it.
7. If the user requires review, do not edit while it is pending. A changed snapshot, skipped/failed required check, missing baseline, `NEEDS FIXES`, or unaccepted follow-up blocks shipping. For review findings, correct only unambiguous in-scope findings, rerun the required checks, and return the fresh snapshot for review; stop and ask or route when a finding reveals ambiguity or scope drift. No review automatically commits or pushes.

## Output format

Changes, verification, acceptance coverage, and deviations or gaps.

## Rules

- Stay within approved scope and use the smallest evidence-backed fit.
- Shared approval policy remains authoritative for every tool.
- When review delegates `NEEDS FIXES`, correct only unambiguous in-scope findings, rerun checks, and request a fresh review; stop for ambiguity or scope drift.
- Same-day changelog maintenance is required only when preparing a user-authorized commit. Include it in the reviewed candidate or reopen review.
- Never claim shipping readiness when required verification or a user-required review gate is absent.
