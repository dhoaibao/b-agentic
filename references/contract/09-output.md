## 9. Output contract

In this source repo, `tooling/policy/output-policy.json` is the machine-readable owner for status, handoff, verdict, cause-class, run-id, and readiness policy. This Markdown file remains the human-readable contract and explanation layer.

### Language

- **Chat:** match the language of the user's most recent message. Code identifiers, paths, and command examples stay in their natural form.
- **Saved artifacts:** English (headings, prose, plan filenames) regardless of chat language, so plans, manifests, and reports remain interoperable. Canonical slugs and run-ids still follow §8.

### Lead with the result

Findings, decisions, or the next action come first. Narration second, if at all. Be concise.

### Verbosity modes

- Default to compact reports: result, material evidence, skipped checks, and next action.
- Expand only for blockers, high-risk boundaries, audits, handoffs, incomplete evidence, or when the user asks for detail.
- Do not include exhaustive tool logs in chat; save or cite logs only when they affect the conclusion.

### Skill-exit status block

Every non-trivial skill run ends with a single fenced status block. Use exactly this schema so downstream skills can parse it:

State values:
- `complete` — requested scope is done and required verification ran or was explicitly skipped.
- `blocked` — work cannot continue without an external fix, unavailable dependency, or failed required check.
- `needs-input` — a user decision or approval is required before safe progress.
- `handed-off` — current skill stopped because another skill owns the next required step.

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

Required fields are `skill`, `state`, `artifacts`, `next`, `blockers`. Every other field is **omit-when-empty** except `cause`, which is required for `blocked` and `needs-input`. Skip the whole line rather than emit a placeholder when an optional field is empty. The `confidence` line, when present, always sits immediately above `notes` so downstream skills can find it at a fixed offset.

`state` reports execution flow; `verdict` reports the skill-specific outcome. For example, a completed review may emit `state: complete` with `verdict: NEEDS FIXES`, and a completed orchestration run may emit `state: complete` with `verdict: READY WITH FOLLOW-UPS`. When a skill defines named verdicts, emit them in `verdict:` instead of burying them in prose or `notes:`.

**run-id conditions** (applies to both `[status]` and `[handoff]` blocks):

| Condition | Include? |
|---|---|
| Wrote artifacts to disk | Yes |
| Part of a handoff chain (source or receiver) | Yes |
| Minted or inherited a non-trivial orchestration run-id | Yes |
| Pure-chat run — no artifacts, no handoff chain | Omit |

#### Named verdicts by skill

**Workflow verdicts** (owned by `b-orchestrate`; emit in `verdict:` on non-trivial workflow close):

| Verdict | Meaning |
|---|---|
| `READY FOR PR` | All phases complete; review passed; required verification ran or accepted skipped checks. |
| `READY WITH FOLLOW-UPS` | Review passed but one or more checks are accepted gaps; safe to ship with named follow-ups. |
| `BLOCKED` | Workflow cannot continue without an external fix or user decision. |
| `IN PROGRESS` | Workflow paused mid-phase; a phase owner is active or a handoff is pending. |

**Diff verdicts** (owned by `b-review`; emit in `verdict:` on review close):

| Verdict | Meaning |
|---|---|
| `READY FOR PR` | Changed code is safe to merge; no blocking findings. |
| `READY WITH FOLLOW-UPS` | Changed code is mergeable with accepted gaps; follow-ups noted. |
| `NEEDS FIXES` | One or more BLOCKER or MAJOR findings must be resolved before merge. |

For UI/browser-relevant work, use `READY FOR PR` only when the relevant browser evidence is covered by supplied/CI evidence, existing-tool evidence, or approved live-browser evidence.

Skill prose that says "close with the skill-exit status block" inherits this schema verbatim; skills must not embed their own copy of the block in output templates.

For trivial happy-path runs (a one-line answer, a tiny edit, or a low-risk local check with direct evidence), omit the block unless the user asked for an audit trail, verification is incomplete, or another skill must continue.

### Saved reports

Save `report.md` only when the user asks for a saved report, a review/audit/checkpoint handoff needs durable evidence, output is too large for chat, or the run produces artifacts that need a manifest. Otherwise prefer the chat report and list `artifacts: none` in the status block.

### Error envelope (failure cause-class)

When `state: blocked` or `state: needs-input`, the `cause` field uses one of these canonical classes so downstream tooling and skills can branch without parsing prose:

| Cause class | Meaning |
|---|---|
| `tool_unavailable` | A required MCP/CLI/server was missing or unreachable. |
| `auth_required` | An auth/permission step blocks progress (user action needed). |
| `user_blocked` | Waiting on a user decision or approval. |
| `iteration_cap` | Hit the §7 cap without resolution; needs new approach or user input. |
| `external_outage` | Third-party service down, registry outage, network failure. |
| `stale_index` | Graph/cache stale and fallback would lose evidence quality. |
| `policy_block` | Action was refused by a safety gate (§6) without approval. |
| `evidence_gap` | Required evidence (test, repro, baseline) is missing and cannot be synthesized. |
| `conflict` | Approved plan conflicts with current repo state or another active artifact. |
| `unsupported` | The request is outside the suite's capability or approved evidence path (e.g., adding unavailable browser/DOM tooling as a side effect). |

A single `cause` per status block. If multiple classes apply, pick the one the user can act on first; mention the others in `blockers`.

### Handoff envelope

When a skill hands off to another skill, emit this fenced block in chat **before** invoking the next skill:

```text
[handoff]
source: <current skill>
run-id: <YYYYMMDD-HHMMSS>-<task-slug>   (see run-id conditions above)
goal: <one-line goal for the next skill>
decisions: <confirmed decisions or 'none'>
assumptions: <open assumptions or 'none'>
files: <relevant paths or 'none'>
verification: <expected check or 'none'>
blockers: <known blockers or 'none'>
carve-outs: <pre-authorized approvals scoped to this run>   (omit the line entirely when empty)
next-skill: <b-skill-name>
```

Required fields are `source`, `goal`, `decisions`, `assumptions`, `files`, `verification`, `blockers`, `next-skill`. `run-id` and `carve-outs` are **omit-when-empty**. The `run-id` propagates per §8 so the receiving skill writes artifacts under the same run.

The receiving skill must read the handoff as its initial source of truth, restate any inherited assumptions that affect execution, and stop if the handoff conflicts with the user's latest instruction or current repo evidence.

### Standard report shape

For non-trivial implementation, debug, test, refactor, review, or research work, final responses include:
- answer, action, or findings first
- verification evidence
- blockers or skipped checks
- confidence signal (§3) when evidence is incomplete
- the natural next action
- the skill-exit status block

### Output verbosity cap

A single skill report must not pad itself to look thorough. Hard caps:

- **BLOCKER findings are never elided.** Every BLOCKER must appear in the report, no matter the count. A BLOCKER by definition prevents shipping; hiding the 16th one risks shipping with unknown blockers.
- **Other-severity findings** (MAJOR / MINOR / NIT): cap at **15 entries per severity**, ranked by impact. Surface the remainder as a one-line `Remaining: N more <severity> findings — request expansion to see them` item.
- **"Checked and clean" entries:** cap at **5**, highest-risk first.
- **Sources / citations:** prefer 2–4 authoritative; never more than 8 unless the user asked for a literature scan.
- **Step-by-step narration:** lead with the result; do not restate every tool call. Tool-by-tool play-by-play belongs in logs, not the report.

When a cap is hit, name it explicitly ("capped at 15 MAJORs") so the user knows the report is bounded, not exhaustive.

---
