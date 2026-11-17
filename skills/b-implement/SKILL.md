---
name: b-implement
description: >
  Execute approved or scoped non-UI work from an approved plan or a small
  direct request, one verified step at a time, handing back to planning or
  research when new ambiguity appears. Frontend/UI code belongs to
  b-frontend. Unlike b-plan, b-implement changes code. Routing signals:
  implement, make the change, apply the plan, code the fix, finish the
  implementation, build the feature.
argument-hint: "[approved plan or change]"
metadata:
  phase: Build
  execution_mode: main
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

- Use native file tools by default and native tools or local search for routine discovery. Follow the kernel CodeGraph rule: before editing indexed code, get the target's callers, blast radius, and affected tests; use native tools for prose, config, and known-path local edits. Use only context supplied in the current task rather than guessing.

## Steps

1. Resolve the approved plan (with its user-confirmed `AC-n` criteria, or `docs/specs/<feature>.md` when present) or direct request. If the expected behavior or acceptance is unspecified or ambiguous and no confirmed criteria exist, route to **b-plan** before editing; a small direct request whose target, expected result, and verification are already known needs no delta. Run `rtk git status --short`, and preserve unrelated changes.
2. Before edits, consult applicable project standards, architecture boundaries, and relevant failure modes. State affected paths, invariants, observable success criteria, and relevant quality constraints. Use repository evidence, including CodeGraph impact for indexed code symbols you will change. If a material behavior or target is missing, use `AskUserQuestion` for the unresolved choice. Group related questions (up to four), but address independent blockers in priority order. Wait for the answer and re-evaluate. Route material external framework/API facts to targeted **b-research** rather than asking the user to supply documentation.
3. Ask the user directly only for material unresolved choices or blockers; do not delegate user decisions to a child. For a non-trivial change whose plan was confirmed with `AC-n` criteria and whose repository already has `docs/specs/`, record the approved spec there as `<feature>.md` using that folder's template with a `Status: approved` line within its first lines (never create the folder unasked), and set `Status: implemented` once its criteria are met.
4. Before adding code or a dependency, check for an existing repository helper, the standard library, a native platform feature, or an already-installed dependency that fits. Make the smallest coherent edit with native tools, matching the target module's local style. Remove imports/helpers made unused by it, but retain unrelated pre-existing dead code.
5. Run the narrowest useful verification. If an unambiguous in-scope defect causes failure, correct it and rerun until required verification passes. If failure reveals ambiguity, scope drift, or an unrelated issue, stop and ask or route rather than guessing. Inspect explicit non-protected changed paths.
6. Inspect every tracked and relevant untracked/derived path and diff. Apply the kernel's risk-triggered review rule to the final candidate against the task baseline after required checks pass. Direct tests/docs and faithfully regenerated outputs count with their source, not as separate subsystems; when the candidate includes regenerated outputs, run the repository's generator check to verify them. For a bounded, verified low-risk change with no trigger, finish and state why independent review was skipped under the low-risk exception. No-change tasks, including PR prose, need no changed-code review.
7. When review is required, freeze and fingerprint the exact candidate with the kernel's snapshot CLI as **b-review** specifies (if it reports `complete: false`, block rather than fall back to manual hashing), then run the independent **b-review** gate with baseline, acceptance, checks, paths, and identity. Compare the identity after it returns and before normal completion; do not edit while review is pending. On `NEEDS FIXES`, follow the kernel and **b-review** fix loop: name each blocker's violated invariant, fix its whole defect class in one batch and one minimal diff limited to the finding's paths, record other ideas as follow-ups, run each finding's regression check and the repository checks, then request a delta re-review carrying the sweep and check results. Missing or failed required checks, unexpected paths, and hand-edited generated outputs block completion even without review.

## Output format

Changes, verification, acceptance coverage reported per `AC-n` when criteria are numbered, and deviations or gaps. Report the low-risk review exception when used; a triggered candidate requires the **b-review** gate before a normal final response.

## Rules

- Stay within approved scope and use the smallest evidence-backed fit.
- Shared approval policy remains authoritative.
- Apply the kernel's risk triggers to changed candidates; no-change outputs must not initiate changed-code review.
- When **b-review** returns `NEEDS FIXES`, correct only unambiguous in-scope blockers, rerun checks, then request a fresh delta re-review; stop for ambiguity or scope drift, and at 3 consecutive rounds.
- Never claim shipping readiness when required verification or a triggered independent review is absent.
