## State machine contract

This contract defines deterministic b-agentic governance. It reduces dependence on model instruction-following by moving observable workflow safety into state, action classification, intent validation, runtime capabilities, and pre-action hooks.

### Enforcement boundary

Strict mode means defined invalid actions are blocked before execution where the runtime exposes pre-action data. It does not make model reasoning correct, prove investigation completeness, or protect information that only exists inside model context.

If a runtime or tool surface cannot provide pre-action interception, b-agentic must report that surface as `advisory-only` and must not claim strict enforcement for it.

### State file

Repo-local workflow state lives at `.b-agentic/state.json`. The model must not edit this file directly. Deterministic tooling writes it through `tooling/state/state.py` using atomic replacement.

Required state fields:
- `version` - schema version, currently `1`.
- `active_skill` - current b-agentic skill or `null`.
- `phase` - lifecycle phase such as `planning`, `implementing`, `reviewing`, or `idle`.
- `source_of_truth` - latest approved plan, user instruction, handoff, or repo evidence anchor.
- `approved_plan` and `approved_head` - saved-plan path and git head when applicable.
- `session_id` - unique session identifier for stale-state recovery.
- `pending_intent` - latest validated action intent or `null`.
- `approvals` - explicit approvals available to validators.
- `capabilities` - runtime enforcement report values: `enforced`, `advisory`, or `unsupported`.
- `last_transition` - previous and next skill/phase with reason and timestamp.

### Runtime capability report

Each runtime must report enforcement capability for these surfaces:
- `state_validation`
- `pre_action_project_write`
- `pre_action_dependency_write`
- `pre_action_destructive`
- `transcript_conformance`

Valid values are:
- `enforced` - deterministic tooling blocks invalid action or output.
- `advisory` - tooling can warn, but cannot reliably block.
- `unsupported` - the runtime/tool surface is unavailable or lacks required payloads.

### Intent record

High-risk actions require a machine-readable intent record before execution:

```text
[intent]
skill: <b-skill-name>
action: project-write | dependency-write | environment-write | external-write | destructive
files: <comma-separated paths or 'none'>
commands: <comma-separated command fragments or 'none'>
source: <plan, handoff, user instruction, or evidence anchor>
approval: not-required | pending | approved | denied
reason: <why this action is required now>
```

At least one target field, `files` or `commands`, must name the intended target. Project writes may use `approval: not-required` when the source of truth already authorizes them. Dependency, environment, external, and destructive actions require `approval: approved`.

### Action validation

Pre-action validators receive runtime payloads, classify the action, and compare it to state and intent.

Risk classes:
- `read-only` - inspect files, git, dependencies, or run non-mutating diagnostics.
- `project-write` - edit approved source, tests, docs, generated assets, or local config.
- `dependency-write` - install, remove, update dependencies, or regenerate lockfiles.
- `environment-write` - start or mutate servers, containers, emulators, DBs, or jobs.
- `external-write` - mutate APIs, staging/prod, queues, payments, email/SMS, analytics, GitHub PRs, or releases.
- `destructive` - delete data/files/branches, reset state, rewrite history, clean worktrees, or drop DBs.

Strict-mode decisions:
- `allow` when action, state, intent, target, approval, and capability match.
- `block` when a high-risk action lacks valid state, intent, target match, approval, or capability.
- `advisory` when strict mode is off.

In strict mode, missing or invalid state, missing target data, unsupported runtime capability, and advisory-only runtime capability are blocking conditions for high-risk actions.

Unknown or ambiguous mutating actions are blocked in strict mode unless explicitly approved by policy.

### Recovery

If state is stale, corrupt, or belongs to a different session, stop and use the state tooling recovery path. Do not hand-edit `.b-agentic/state.json` in a model response. Recovery may reinitialize state, transition to `blocked`, or record advisory-only capabilities.

---
