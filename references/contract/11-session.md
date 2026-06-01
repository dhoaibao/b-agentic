## 11. Session lifecycle

### Session-start preflight (run once at first non-trivial action)

1. `git status --short` — note dirty state; preserve unrelated changes (§6).
2. Note whether the current checkout is already isolated (linked worktree, harness-provided workspace, or equivalent). Reuse existing isolation; do not nest it casually.
3. Check for an approved plan under `.b-agentic/b-plan/` matching the current request.
4. Confirm MCP availability lazily on first use.
5. Acknowledge dirty state only when it could affect the request.

### Crash/resume

- If a prior session left a partially complete run directory under `.b-agentic/<skill>/<run-id>/`, resume from its manifest's last `complete` artifact rather than restarting.
- If no manifest exists, treat the directory as orphaned; do not delete it without asking.
- For saved plans, use the staleness gate (§2) to decide whether to resume or re-plan.
- Across runtime adapters, assume operator-resumed continuation: the user or orchestrator supplies the latest `[status]` or `[handoff]` block, and the receiving skill reuses the carried run-id when one exists.
- If the previous status named artifacts under `.b-agentic/<skill>/<run-id>/`, the active runtime's user-scope b-agentic directory, or `/tmp/<runtime>/b-agentic/<skill>/<run-id>/`, inspect only the needed files and preserve unrelated historical run directories.

### Cross-skill conventions

Skill bodies should contain only the trigger boundary, the skill's task-specific workflow, and task-specific stop conditions. Handoff envelopes and status blocks are the suite's only portable cross-skill contract; assume that no native phase-to-phase continuation exists unless a runtime adapter explicitly documents it. Reference pointers in skill bodies are not optional — read the named reference before continuing.

---
