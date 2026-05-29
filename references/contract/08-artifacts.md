## 8. Artifacts

### Slug algorithm

Derive `<task-slug>` from the user's request:
1. Take the imperative form of the request (drop polite filler, English or Vietnamese).
2. Lowercase. Replace any non-ASCII (including Vietnamese diacritics) with the closest ASCII equivalent.
3. Replace non-alphanumeric runs with `-`. Trim leading/trailing `-`.
4. Cap at **40 characters**. If truncation would split a word, end at the previous `-`.
5. If a collision exists with an unrelated active plan or run, append `-2`, `-3`, … (numeric only; never random suffixes).

Examples:
- "Add rate limiting to the API" → `add-rate-limiting-to-the-api`
- "Đổi tên UserService thành UserRepository" → `doi-ten-userservice-thanh-userrepository`

### Saved plan filename

Saved plan paths use an English `<plan-file-slug>`:

1. Base it on the plan's English H1 title or one-line goal.
2. Lowercase. Keep important identifiers, API names, and code symbols in their natural form.
3. Replace non-alphanumeric runs with `-`. Trim leading/trailing `-`.
4. Cap at **40 characters**. If truncation would split a word, end at the previous `-`.
5. If a collision exists with another saved plan filename, append `-2`, `-3`, … (numeric only).
6. Once created, keep the filename stable through revisions unless the user explicitly asks to rename or supersede the plan.

The frontmatter field `slug: <task-slug>` remains the canonical deterministic identifier for matching, dependencies, cross-skill references, and any run-id continuity. Do not replace it with the English filename slug.

### Run ID

`<YYYYMMDD-HHMMSS>-<task-slug>`. All skills use this format.

### Run-id continuity across handoffs

When one skill hands off to another for the same logical task, the receiving skill **reuses** the source skill's `<run-id>` and writes its own artifacts under `.b-agentic/<receiving-skill>/<run-id>/`. Continuity rules:

- A new `<run-id>` is minted only on a fresh user task, not on a handoff.
- Non-trivial `b-orchestrate` workflows mint a `<run-id>` at workflow start, even before artifacts exist, so every phase handoff can be tied to the same logical task.
- The handoff envelope (§9) must carry the `run-id` **whenever one exists** — i.e., whenever the source skill wrote artifacts, itself inherited a `run-id` from an earlier handoff, or `b-orchestrate` minted one for a non-trivial workflow. Pure chat-only handoffs that have produced no artifacts and are not part of a non-trivial orchestration may omit the `run-id` field; the receiving skill mints one if and when it first writes an artifact.
- When a chain of skills (e.g., `b-plan -> b-implement -> b-review`) all act on the same task and any one of them has written artifacts, every subsequent run directory shares the same `<run-id>` even though each lives under a different `<skill>` subdirectory.

### Non-plan artifact naming

Files inside a run directory follow these conventions so they're predictable across skills:
- `report.md` — the skill's final human-readable report.
- `manifest.json` — the run manifest (schema below).
- `<topic>.log` — captured command output (e.g., `pnpm-test.log`, `test-run.log`).
- `<topic>.snapshot.{txt|json}` — captured tool snapshots (a11y trees, diagnostics dumps).
- `screenshot-<step>.png` — browser screenshots, numbered by interaction order.
- Anything else: lowercase-kebab-case with an explicit content suffix.

### Paths

- Global install, update, and uninstall are user-scope flows. They do not create repo-local `.b-agentic/` paths in the caller's current repo; the `.b-agentic/.gitignore` guard is created only when an active skill or other explicitly repo-local artifact path writes there.
- **Plans:** `.b-agentic/b-plan/<plan-file-slug>.md` (canonical path) after applying the `.b-agentic/.gitignore` guard in §6. Saved plans remain repo-local source-of-truth files. Frontmatter `slug: <task-slug>` stays canonical for matching and continuity. The legacy `.opencode/b-agentic/` and `.opencode/b-plans/` paths are deprecated; do not write there.
- **Skill artifacts:** `.b-agentic/<skill>/<run-id>/` for repo-local non-sensitive b-agentic artifacts after applying the `.b-agentic/.gitignore` guard in §6.
- **Saved reports:** `.b-agentic/<skill>/<run-id>/report.md` for explicit review/research reports after applying the `.b-agentic/.gitignore` guard in §6.
- **Sensitive artifacts:** auth/session state and similar secrets default to the active runtime's user-scope b-agentic directory or temp scratch path (for example, `~/.claude/b-agentic/<skill>/<run-id>/`, `~/.config/opencode/b-agentic/<skill>/<run-id>/`, `~/.codex/b-agentic/<skill>/<run-id>/`, `~/.gemini/antigravity-cli/b-agentic/<skill>/<run-id>/`, `/tmp/claude-code/b-agentic/<skill>/<run-id>/`, `/tmp/opencode/b-agentic/<skill>/<run-id>/`, `/tmp/codex-cli/b-agentic/<skill>/<run-id>/`, or `/tmp/antigravity-cli/b-agentic/<skill>/<run-id>/`); never store them in a tracked worktree path.
- **Temporary logs:** the active runtime's temp scratch path (for example, `/tmp/claude-code/b-agentic/<skill>/<slug>.log`, `/tmp/opencode/b-agentic/<skill>/<slug>.log`, `/tmp/codex-cli/b-agentic/<skill>/<slug>.log`, or `/tmp/antigravity-cli/b-agentic/<skill>/<slug>.log`).

Do not invent new b-agentic artifact paths. Project-native verification outputs such as coverage reports, test traces, videos, screenshots, snapshots, or framework `test-results` may be produced in the repo's configured locations when running an approved or risk-appropriate command; report them when they affect evidence, cleanup, or generated-artifact provenance.

### Artifact minimization

- Do not create run artifacts for routine chat answers, tiny edits, or successful low-risk checks.
- Create b-agentic artifacts only when needed for saved plans, explicit saved reports, screenshot evidence, large/truncated logs, auth/session state, generated evidence, partial failures, or user-requested auditability.
- If an artifact is optional, prefer the chat/status summary over writing files.

### Workflow checkpoints

For non-trivial `b-orchestrate` workflows, checkpoint the phase state whenever the workflow pauses for approval, a blocker, a review-fix loop, or a session handoff. Use the existing `b-orchestrate` run-id. If the workflow cannot continue in the same turn or needs durable resume evidence, write `report.md`; otherwise carry the checkpoint in the required status/handoff blocks.

### Retention and cleanup

- Keep saved plans and explicit review/research reports until the user removes them; they are source-of-truth or decision artifacts.
- Treat active-runtime temp scratch artifacts (for example, `/tmp/claude-code/b-agentic/...`, `/tmp/opencode/b-agentic/...`, `/tmp/codex-cli/b-agentic/...`, or `/tmp/antigravity-cli/b-agentic/...`) as disposable scratch. Report their paths when they matter, but do not promise persistence.
- Delete or avoid creating sensitive artifacts unless they are required for the task. Auth/session state should live in a non-worktree path and be named in the final report.
- When a run creates test data, browser state, screenshots, logs, or generated files, report what was kept, cleaned up, or left for the user to decide.
- Old run directories or saved plans that do not match the current task are historical artifacts. Do not delete or reuse them unless a manifest or plan status explicitly says to resume, or the user asks for cleanup.

### Manifest schema

Any run that produces more than one artifact must include `manifest.json` at the root of its run directory:

```json
{
  "run_id": "<YYYYMMDD-HHMMSS>-<task-slug>",
  "skill": "<b-skill-name>",
  "status": "complete | blocked | partial",
  "artifacts": ["<relative-path>", "..."],
  "notes": "<one-line summary>"
}
```

Single-artifact runs may skip the manifest and report these fields inline instead. Manifests must be valid JSON and should not include comments or trailing commas.

### Manifest state transitions

- `partial` means the run produced useful artifacts or edits but did not satisfy completion. A receiving skill must inspect `notes`, `blockers`, and generated files before resuming.
- Valid forward transitions are `partial -> complete | blocked`, `blocked -> complete | partial` after the blocker is resolved, and `complete` only by a new run or explicit revision. Do not silently overwrite a previous manifest state.

---
