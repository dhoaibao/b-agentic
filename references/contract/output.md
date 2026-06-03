## Output contract

`tooling/policy/output-policy.json` is the machine-readable owner for status, handoff, verdict, cause-class, run-id, and readiness policy. This file is the human-readable contract.

Lead with the result, decision, finding, or next action. Expand only for blockers, high-risk boundaries, audits, handoffs, incomplete evidence, or explicit user request.

### Skill-exit status block

Every non-trivial skill run ends with one fenced status block:

```text
[status]
skill: <b-skill-name>
run-id: <YYYYMMDD-HHMMSS>-<task-slug>
state: complete | blocked | needs-input | handed-off
artifacts: <comma-separated paths or 'none'>
next: <skill name or 'none'>
blockers: <one-line list or 'none'>
cause: <cause-class>   (required when state is 'blocked' or 'needs-input'; omit otherwise)
verdict: <skill-defined terminal label>
confidence: high | medium | low - <reason>
notes: <cost summary, pre-auth carve-outs, or other run-scoped notes>
```

Required fields: `skill`, `state`, `artifacts`, `next`, `blockers`. Optional fields: `run-id`, `cause`, `verdict`, `confidence`, `notes`. Omit optional lines when empty. `confidence`, when present, sits immediately above `notes`.

State values:
- `complete` - requested scope is done and required verification ran or was explicitly skipped.
- `blocked` - cannot continue without an external fix, unavailable dependency, or failed required check.
- `needs-input` - user decision or approval is required.
- `handed-off` - another skill owns the next required step.

`state` reports execution flow; `verdict` reports the skill-specific outcome.

Run-id conditions:

| Condition | Include? |
|---|---|
| Wrote artifacts to disk | Yes |
| Part of a handoff chain (source or receiver) | Yes |
| Pure-chat run — no artifacts, no handoff chain | Omit |

### Cause classes

| Cause | Meaning |
|---|---|
| `tool_unavailable` | Required MCP/CLI/server missing or unreachable |
| `auth_required` | Auth or permission step blocks progress |
| `user_blocked` | Waiting on user decision or approval |
| `iteration_cap` | Iteration cap hit without resolution |
| `external_outage` | Third-party outage or network failure |
| `stale_index` | Graph/cache stale and fallback would lose evidence quality |
| `policy_block` | Safety gate refused action without approval |
| `evidence_gap` | Required evidence is missing and cannot be synthesized |
| `conflict` | Plan conflicts with repo state or active artifact |
| `unsupported` | Request is outside suite capability or approved evidence path |

### Review verdicts

| Verdict | Meaning |
|---|---|
| `READY FOR PR` | Changed code is safe to merge: no blocking findings and required evidence is covered. |
| `READY WITH FOLLOW-UPS` | Changed code is mergeable with accepted gaps. |
| `NEEDS FIXES` | One or more BLOCKER or MAJOR findings must be resolved before merge. |

For reviews, `READY FOR PR` requires no blocking findings. For UI/browser-relevant work, `READY FOR PR` requires accepted browser evidence from supplied/CI evidence, existing-tool evidence, or approved live-browser evidence.

### Handoff envelope

Emit before handing off to another skill:

```text
[handoff]
source: <current skill>
run-id: <YYYYMMDD-HHMMSS>-<task-slug>
goal: <one-line goal for the next skill>
decisions: <confirmed decisions or 'none'>
assumptions: <open assumptions or 'none'>
files: <relevant paths or 'none'>
verification: <expected check or 'none'>
blockers: <known blockers or 'none'>
carve-outs: <pre-authorized approvals scoped to this run>
next-skill: <b-skill-name>
```

Required fields: `source`, `goal`, `decisions`, `assumptions`, `files`, `verification`, `blockers`, `next-skill`. Optional fields: `run-id`, `carve-outs`. The receiving skill treats the handoff as source of truth unless it conflicts with the latest user instruction or repo evidence.

Save reports only when requested, when a durable handoff/checkpoint needs evidence, output is too large for chat, or artifacts need a manifest.

---
