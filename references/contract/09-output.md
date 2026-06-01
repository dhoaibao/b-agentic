## 9. Output contract

`tooling/policy/output-policy.json` is the machine-readable owner for status, handoff, verdict, cause-class, run-id, and readiness policy. This file is the human-readable contract.

### Language and shape

- Chat: match the user's most recent language; keep code identifiers and paths in their natural form.
- Saved artifacts: English headings/prose/filenames for interoperability.
- Lead with the result, decision, finding, or next action. Keep narration compact.
- Expand only for blockers, high-risk boundaries, audits, handoffs, incomplete evidence, or explicit user request.

### Skill-exit status block

Every non-trivial skill run ends with one fenced status block:

```text
[status]
skill: <b-skill-name>
run-id: <YYYYMMDD-HHMMSS>-<task-slug>   (see run-id conditions below)
state: complete | blocked | needs-input | handed-off
artifacts: <comma-separated paths or 'none'>
next: <skill name or 'none'>
blockers: <one-line list or 'none'>
cause: <cause-class>   (required when state is 'blocked' or 'needs-input'; omit otherwise)
verdict: <skill-defined terminal label>   (omit when the skill does not define named verdicts)
confidence: high | medium | low — <reason>   (omit when high and evidence is direct)
notes: <cost summary, pre-auth carve-outs, or other run-scoped notes>   (required when any [degraded:] label was emitted; omit otherwise when empty)
```

Required fields: `skill`, `state`, `artifacts`, `next`, `blockers`. Omit optional lines when empty. `confidence`, when present, sits immediately above `notes`.

State values:
- `complete`: requested scope is done and required verification ran or was explicitly skipped.
- `blocked`: cannot continue without an external fix, unavailable dependency, or failed required check.
- `needs-input`: user decision or approval is required.
- `handed-off`: another skill owns the next required step.

`state` reports execution flow; `verdict` reports the skill-specific outcome.

Named `b-review` verdicts:

| Verdict | Meaning |
|---|---|
| `READY FOR PR` | Changed code is safe to merge; no blocking findings. |
| `READY WITH FOLLOW-UPS` | Changed code is mergeable with accepted gaps; follow-ups noted. |
| `NEEDS FIXES` | One or more BLOCKER or MAJOR findings must be resolved before merge. |

For UI/browser-relevant work, use `READY FOR PR` only when relevant browser evidence is covered by supplied/CI evidence, existing-tool evidence, or approved live-browser evidence.

Run-id conditions:

| Condition | Include? |
|---|---|
| Wrote artifacts to disk | Yes |
| Part of a handoff chain (source or receiver) | Yes |
| Pure-chat run — no artifacts, no handoff chain | Omit |

Trivial happy-path runs may omit the block unless verification is incomplete, the user asked for an audit trail, or another skill must continue.

### Cause classes

Use one cause when `state` is `blocked` or `needs-input`:

| Cause | Meaning |
|---|---|
| `tool_unavailable` | Required MCP/CLI/server missing or unreachable |
| `auth_required` | Auth or permission step blocks progress |
| `user_blocked` | Waiting on user decision or approval |
| `iteration_cap` | §7 cap hit without resolution |
| `external_outage` | Third-party outage or network failure |
| `stale_index` | Graph/cache stale and fallback would lose evidence quality |
| `policy_block` | Safety gate refused action without approval |
| `evidence_gap` | Required evidence is missing and cannot be synthesized |
| `conflict` | Plan conflicts with repo state or active artifact |
| `unsupported` | Request is outside suite capability or approved evidence path |

If multiple causes apply, pick the one the user can act on first and mention others in `blockers`.

### Handoff envelope

Emit before handing off to another skill:

```text
[handoff]
source: <current skill>
run-id: <YYYYMMDD-HHMMSS>-<task-slug>   (omit unless run-id conditions apply)
goal: <one-line goal for the next skill>
decisions: <confirmed decisions or 'none'>
assumptions: <open assumptions or 'none'>
files: <relevant paths or 'none'>
verification: <expected check or 'none'>
blockers: <known blockers or 'none'>
carve-outs: <pre-authorized approvals scoped to this run>   (omit when empty)
next-skill: <b-skill-name>
```

Required fields: `source`, `goal`, `decisions`, `assumptions`, `files`, `verification`, `blockers`, `next-skill`. The receiving skill treats the handoff as initial source of truth and stops if it conflicts with latest user instruction or repo evidence.

### Reports and caps

Save `report.md` only when requested, when a durable handoff/checkpoint needs evidence, output is too large for chat, or artifacts need a manifest.

Final reports for non-trivial runs include result, verification evidence, skipped checks or blockers, incomplete-evidence confidence when relevant, and the natural next action.

Caps: never elide BLOCKER findings; cap other severities at 15 each; cap "checked and clean" entries at 5; prefer 2-4 authoritative sources and never more than 8 unless requested.

---
