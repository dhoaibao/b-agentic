## 0. Relationship To Runtime Kernel

The authoritative active runtime kernel lives under `runtimes/<name>/kernel.md` in this source repo and installs as the runtime's memory file when the user permits activation. This detailed contract must not duplicate the kernel rule list; it expands the schemas, rubrics, tool bundles, and edge-case protocols that the kernel links to.

### Reference checklist

References to this contract and to other `references/b-agentic/*.md` files are checklist hints — read the smallest named section or file before using it; do not reconstruct shared details from memory. Adherence is voluntary self-guidance; the runtime has no enforcement hook. This applies especially to saved-plan metadata, plan staleness, MCP bundle rules, approval asks, privacy gates, artifact manifests, status blocks, handoff envelopes, review/audit checklists, and performance guidance.

### Runtime gate taxonomy

Runtime-critical gates are the points where missed instructions most often create incorrect behavior. Skill files must expose these as explicit read-before-use actions at the step that needs them, not as passive pointers at the end of the file.

- **Routing gate (§1, §10):** before acting on overlapping intents, switching skills, test-vs-bug decisions, or browser/DOM verification boundaries.
- **Source-of-truth gate (§2):** before executing saved or chat plans, checking plan metadata, applying staleness rules, or revising approved plans.
- **Risk/readiness gate (§3):** before classifying non-trivial work, risk, readiness, severity, or confidence.
- **Tool/evidence gate (§4, §5):** before using MCP bundles, web extraction, citations, freshness labels, or degraded evidence.
- **Safety/approval gate (§6):** before dependency writes, external sends, destructive commands, shared-environment mutation, privacy-sensitive extraction, or repo-local artifact writes.
- **Execution/verification gate (§7):** before scope expansion, iteration loops, rollback, cascading-failure handling, verification, or completion claims.
- **Artifact gate (§8):** before writing saved plans, reports, manifests, run logs, sensitive artifacts, or non-plan run directories.
- **Output/handoff gate (§9):** before emitting non-trivial final output, status blocks, saved reports, error envelopes, or handoff envelopes.

Use this wording pattern in installed runtime skills when a gate is required: `Read ${CLAUDE_SKILL_DIR}/references/b-agentic/contract/ §N before <action>`. For a per-skill `reference.md`, use: `Read ${CLAUDE_SKILL_DIR}/reference.md before <action>`. `${CLAUDE_SKILL_DIR}` is the current shared delivery bridge marker in generated assets, not a claim that every runtime stores skills in Claude Code-specific locations. Keep schemas in this contract; the skill owns only the local trigger for reading them.

### Runtime gate checklist

For non-trivial runs, apply the gates as checkpoints rather than as ceremony on every message:

1. **Start:** choose one active skill, identify the source of truth, and read any immediately needed routing/source sections.
2. **Pre-edit or pre-external:** confirm approval, staleness, worktree state, safety/privacy gates, and planned verification.
3. **Pre-final or pre-switch:** confirm required verification, artifact state, unresolved blockers, and read §9 before status or handoff output.

Trivial happy paths keep the compact path in §7 and §9; do not add status blocks or saved artifacts solely to prove that the checklist was considered.

### Kernel/detail split for the shared sections

- `§2 Source of truth` — keep the conflict ladder, non-invention rule, and glossary-doc reminder in the kernel; plan metadata, executable-state checks, staleness, and revision protocol live here.
- `§3 Definitions and rubrics` — the kernel may summarize planning/readiness posture, but the canonical definitions of `non-trivial`, `small direct request`, risk, severity, and confidence live here.
- `§5 Evidence standards` — the kernel may keep evidence posture in one paragraph, but the hierarchy, citation/freshness labels, and happy-path compression live here.
- `§6 Safety gates` — the kernel may remind users to ask before risky mutation and to protect secrets, but command classes, approval ask shape, privacy gates, artifact safety, patch discipline, and git safety live here.
- `§7 Execution discipline` — the kernel may keep the smallest-safe-path posture, but scope expansion, verification ladder, iteration cap, rollback, and completion rules live here.
- `§8 Artifacts` — the kernel may require shared slug/run-id usage, but paths, manifests, retention, and continuity live here.
- `§9 Output contract` — the kernel may require the use of `[status]` and `[handoff]`, but the exact field schema lives here.
- `§10 Cross-cutting decisions` — the kernel may keep high-risk completion cues, but the shared decision tables and edge-case procedures live here.

### Contract Version

This runtime contract version is `2026-05-16`. New saved plans and multi-artifact manifests should include this value as `contract_version` so future agents can detect stale artifact semantics. In schema examples and reusable templates, write the field as `<current-contract-version>` to avoid drift; concrete run artifacts use the actual version string from this section. Legacy artifacts without this field remain valid but should be treated as pre-versioned.

---
