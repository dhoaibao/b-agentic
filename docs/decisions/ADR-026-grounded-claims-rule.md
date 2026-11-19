# ADR-026: A grounded-claims rule in the kernel, paid for by trimming existing text

- Status: Accepted
- Date: 2026-11-19
- Supersedes: none; refines [ADR-022](ADR-022-discussion-first-entry.md) (its rejection of a kernel rule line for lack of byte headroom)

## Context

The kernel had no general rule that a claim names its basis. Its only grounding text covered
work, not statements: rule 9 ("evidence-backed fit") and "never invent behavior or
compatibility". Specialist skills carry the idea for their own output (`b-research`, `b-audit`,
`b-agentic-audit`, `b-plan`, `b-debug`, `b-qa`), but the main-session skills (`b-implement`,
`b-test`, `b-flow`, `b-frontend`, `b-refactor`) and direct answers have no such rule, and the main
session owns final reporting. No violation was observed; the gap was found by reading the rules.

The kernel is limited to 12,000 bytes and 100 lines
(`tooling/generate/registry_sync.py`, checked by `registry_sync.py --check`) and had 58 bytes of
headroom, so a new rule line had to be paid for.

## Decision

- Add rule 11 to `Core Rules`: `Cite the basis of each claim (code read, check run, doc, review,
ticket, user); else say "not checked" or "unknown"; label any inference.`
- Pay for it by shortening rule 10 without changing its meaning and by removing the sentence
  "Configured never means authenticated, verified, or used." from Capability activation; the
  new rule covers it, and `REFERENCE.md` keeps the close statement "Configured does not mean
  connected or usable". The kernel ends at 11,998 bytes and 99
  lines.
- Inference is allowed when labeled, not forbidden. `b-plan`, `b-design`, and `b-debug` already
  require labeled inference, and a flat ban would contradict them while the kernel has no rule
  for which text wins.
- Guard the rule with `GROUNDED_CLAIMS_REGRESSION` in `tooling/validate/behavior.py`, because
  the kernel sits within two bytes of its limit and a later trim could remove the rule without
  any check noticing.
- Rejected: extending rule 8 (its text is locked by `OUTPUT_SHAPE_REGRESSION`, it concerns answer
  shape, and it ends by ranking skill output contracts above it); appending to rule 9 (two
  concerns in one rule, and only about 4 bytes saved); adding the rule to each main-session skill
  (five prompts and regenerated files, and direct answers outside any skill stay uncovered);
  a hook or validator that checks citations in output (pattern-matching missing citations is
  unreliable, the same reasoning as ADR-022, and no violation justifies it); raising
  `MAX_KERNEL_BYTES` ([ADR-012](ADR-012-run-first-entry.md) rejected raising the limit).

## Consequences

- Every session loads one more rule; headroom is now 2 bytes, so any later kernel addition must
  trim existing text first.
- Whether the rule changes model behavior is not tested by any validator. The regression entry
  only proves the wording is present; the effect is confirmed by the user in a live session after
  the installer refreshes `~/.claude`, which this change does not do.
- The rule and labeled-inference skills overlap by design; when a skill's output contract is
  stricter, that skill's text applies to its own output.

Evidence: [`references/kernel.template.md`](../../references/kernel.template.md),
[`tooling/validate/behavior.py`](../../tooling/validate/behavior.py),
[`tooling/generate/registry_sync.py`](../../tooling/generate/registry_sync.py),
[`skills/b-plan/prompt.md`](../../skills/b-plan/prompt.md),
[`skills/b-research/prompt.md`](../../skills/b-research/prompt.md).
