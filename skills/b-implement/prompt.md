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
3. Ask the user directly with `ask_user_question` only for material unresolved choices or blockers. Group related questions up to four; address independent blockers in priority order and wait for each answer.
4. Make the smallest coherent edit with native tools, matching the target module's local style. Remove imports/helpers made unused by it, but retain unrelated pre-existing dead code.
5. Run the narrowest useful verification. If an unambiguous in-scope defect causes failure, correct it and rerun until required verification passes. If failure reveals ambiguity, scope drift, or an unrelated issue, stop and ask or route rather than guessing. Inspect explicit non-protected changed paths.
6. When the scoped task is complete and required checks pass, freeze every tracked plus relevant untracked/derived candidate and request **b-reviewer** review before a normal final response. No-change tasks, including PR prose, do not require changed-code review.
7. Do not edit while review is pending. A changed snapshot, skipped/failed required check, missing baseline, `NEEDS FIXES`, or unaccepted follow-up blocks shipping. For `NEEDS FIXES`, correct only unambiguous in-scope findings, rerun the required checks, then freeze a fresh candidate and request review. No review automatically commits or pushes.

## Output format

Changes, verification, acceptance coverage, and deviations or gaps. A changed candidate requires the **b-reviewer** gate and pause before a normal final response.

## Rules

- Stay within approved scope and use the smallest evidence-backed fit.
- Shared approval policy remains authoritative.
- Automatic review is mandatory for changed candidates; no-change outputs must not initiate it.
- When **b-reviewer** returns `NEEDS FIXES`, correct only unambiguous in-scope findings, rerun checks, then request a fresh review; stop for ambiguity or scope drift.
- Same-day changelog maintenance is required only when preparing a user-authorized commit. Include it in the reviewed candidate or reopen review.
- Never claim shipping readiness when required verification or the independent review gate is absent.
