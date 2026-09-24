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

- Use native file tools by default and native tools or local search for routine discovery. Select CodeGraph only when a repository-wide architecture, impact, or affected-test question is central. Use only context supplied in the current task rather than guessing.

## Steps

1. Resolve the approved plan or direct request, run `rtk git status --short`, and preserve unrelated changes.
2. Before edits, consult applicable project standards, architecture boundaries, and relevant failure modes. State affected paths, invariants, observable success criteria, and relevant quality constraints. Use repository evidence; select CodeGraph only for a concrete central repository-wide question. If a material behavior or external fact is missing, stop and ask the user one focused question about the decision, target, or source/version needed. Wait for the answer and re-evaluate before handing off; do not ask multiple independent blocker questions at once. Once clarified, route remaining material framework/API best-practice uncertainty to targeted **b-research**.
3. Ask the user directly with `ask_user_question` only for material unresolved choices or blockers. Group related questions up to four; address independent blockers in priority order and wait for each answer.
4. Make the smallest coherent edit with native tools, matching the target module's local style. Remove imports/helpers made unused by it, but retain unrelated pre-existing dead code.
5. Run the narrowest useful verification. If an unambiguous in-scope defect causes failure, correct it and rerun until required verification passes. If failure reveals ambiguity, scope drift, or an unrelated issue, stop and ask or route rather than guessing. Inspect explicit non-protected changed paths.
6. Inspect every tracked and relevant untracked/derived path and diff. Apply the kernel's risk-triggered review rule to the final candidate against the task baseline after required checks pass. Direct tests/docs and faithfully regenerated outputs count with their source, not as separate subsystems; when the candidate includes regenerated outputs, run the repository's generator check to verify them. For a bounded, verified low-risk change with no trigger, finish and state why independent review was skipped under the low-risk exception. No-change tasks, including PR prose, need no changed-code review.
7. When review is required, freeze the exact candidate and request **b-reviewer** review before normal completion. Do not edit while review is pending. A changed reviewed snapshot, missing baseline, `NEEDS FIXES`, or unaccepted follow-up requires correction, fresh checks, and new review. Missing or failed required checks, unexpected paths, and hand-edited generated outputs block completion even without review; ask the user about ambiguous acceptance, and name the closest trigger before escalating uncertain risk to review. No review automatically commits or pushes.

## Output format

Changes, verification, acceptance coverage, and deviations or gaps. Report the low-risk review exception when used; a triggered candidate requires the **b-reviewer** gate before a normal final response.

## Rules

- Stay within approved scope and use the smallest evidence-backed fit.
- Shared approval policy remains authoritative.
- Apply the kernel's risk triggers to changed candidates; no-change outputs must not initiate changed-code review.
- When **b-reviewer** returns `NEEDS FIXES`, correct only unambiguous in-scope findings, rerun checks, then request a fresh review; stop for ambiguity or scope drift.
- Never claim shipping readiness when required verification or a triggered independent review is absent.
