# b-skills — OpenCode Global Rules

> Short rules enforced every turn. Skill-specific workflows live in `skills/*/SKILL.md`.

---

## Skill Routing

Match the user's intent to one active skill before answering inline. If a request spans phases, run skills in order: Decide -> Build -> Validate.

| Intent | Skill |
|---|---|
| Decide what to build, decompose work | `/b-plan` |
| External docs, API facts, comparisons | `/b-research` |
| Execute an approved/scoped plan | `/b-implement` |
| Mechanical rename, extract, move, inline, delete | `/b-refactor` |
| Runtime bug, error, "not working" | `/b-debug` |
| Unit/integration tests, coverage, failing tests | `/b-test` |
| Browser/UI verification or Playwright authoring | `/b-e2e` |
| Pre-PR changed-code review | `/b-review` |

Switch skills only at a documented handoff condition. Keep one active skill until its stop condition is hit; do not switch skills for optional enrichment or minor lookups that the current skill can finish with bounded evidence. Ask the smallest concrete question when a user decision blocks progress.

When switching skills, include a compact handoff: `source`, `scope`, `files`, `commands`, `blockers`, and `next skill`. Do not rely on prior chat context when a saved plan or changed artifact is the source of truth.

---

## Tool Priority

Use the lightest capable tool that can answer reliably. Prefer a relevant MCP over native fallbacks only when it materially reduces ambiguity, avoids broad manual searching, or provides evidence native tools cannot. Native Glob/Grep/Read/Bash remain appropriate for file discovery, exact strings, manifests, prose, configs, and command execution.

| Task shape | First choice | Then narrow with |
|---|---|---|
| Graph overview, architecture, blast radius, changed-scope validation | `gitnexus:*` when indexed, fresh, and target-aware | `serena:*` |
| Exact symbol discovery, body inspection, references, symbol edits | `serena:*` | Native tools + `apply_patch` |
| Library/framework docs | `context7:*` | `/b-research` |
| Web search | `brave-search` | `firecrawl_search`, then `webfetch` |
| Known URL extraction | `firecrawl_scrape` | `firecrawl_interact`, then `firecrawl_map` |
| Local document extraction | `firecrawl_parse` | `firecrawl_scrape` only if the file is already hosted |
| Browser automation | `playwright:*` via `/b-e2e` | none |
| Multi-hypothesis reasoning | `sequential-thinking` | inline evidence table |

**Radar/hands boundary**: GitNexus is optional radar; Serena is primary hands. GitNexus scopes graph risk, flows, routes, and cross-module/cross-repo impact. Serena confirms exact symbols, bodies, references, and performs symbol-aware edits.

**Parallel-use model**:
- Ask GitNexus graph questions: What process/route/module is involved? Who consumes this contract? How wide is the blast radius?
- Ask Serena code questions: Which exact symbol is this? Where is its declaration? What does its body do? What references must be updated?
- Do not use both MCPs to answer the same exact question. Once GitNexus has narrowed the area, switch to Serena for source-of-truth inspection and edits.
- Return to GitNexus only when a new graph question appears after Serena inspection, such as a newly discovered shared boundary, route consumer, or contract surface.
- In normal flows, one GitNexus pass is enough before Serena takes over.

**GitNexus freshness gate**: rely on GitNexus only when the repo is indexed, not stale, and the target file/symbol is represented. If unavailable, stale, unindexed, missing FTS, or missing the target, warn once and continue with Serena/native tools. Stale graph output is not evidence.

For symbol-aware work, call `check_onboarding_performed`; if false, call `onboarding` once. Run this Serena preflight once per skill run when Serena first becomes necessary, not before every later symbol step in the same run. Use `apply_patch` for manual file edits.

**Tool budget**:
- Single-file/local task: skip GitNexus.
- Simple path, manifest, exact-string, prose, or config lookup: native tools first.
- Known symbol edit: Serena first; GitNexus only for exported/shared or cross-boundary symbols.
- Large unfamiliar area: GitNexus once to narrow, then Serena confirms.
- Review/debug: GitNexus only for cross-file, flow, route/API, or changed-scope risk.
- Never run GitNexus and Serena in parallel for the same symbol hunt; use them sequentially to avoid overlapping evidence.
- Do not escalate to a second MCP when the first authoritative source already answered the question well enough to act.
- Tool names in skill prose describe MCP capabilities; actual calls must use the exact tool names exposed by the current OpenCode session.

**Evidence standards**:
- Graph evidence = GitNexus relationships/processes/routes/impact; use for prioritization, not proof.
- Symbol evidence = Serena bodies/references/overviews/edits; use as the code-change source of truth.
- Text evidence = exact matches from native tools; use for manifests, config, prose, imports, and strings.
- Runtime evidence = tests, builds, browser state, network calls, logs; use to verify behavior.

---

## Coding Principles

- Think before coding: state assumptions, ask when behavior/product choices are unclear, and choose the smallest safe path.
- Keep changes surgical: no speculative features, broad cleanup, single-use abstractions, or unrelated formatting.
- Prefer editing existing files over creating new ones unless the existing structure requires a new file.
- Define success before acting on non-trivial work and stop at verified, not merely implemented.
- Trust but verify subagents with actual diffs, files, or command output before reporting completion.

---

## Approval Gates

Ask before starting package installs, dev servers, migrations, destructive commands, production-like/staging data writes, broad refactors, or commits. For clearly scoped code edits, proceed without asking unless the edit changes user-visible behavior beyond the request.

If a task says only "why" or asks for diagnosis/explanation, stop after confirmed root cause unless the user also asked for a fix. If a task asks to fix, debug, implement, or apply changes, continue through the relevant skill's edit and verification loop.

---

## Artifact Paths

- Plans: `.opencode/b-plans/<task-slug>.md`.
- Run IDs: `<YYYYMMDD-HHMMSS>-<slug>`.
- Skill artifacts: `.opencode/b-skills/<skill>/<run-id>/`.
- E2E artifacts: `.opencode/b-skills/b-e2e/<run-id>/`.
- Temporary logs: `/tmp/opencode/b-skills/<skill>/<slug>.log`.
- Do not write generated artifacts elsewhere unless editing project source files is the task.
- If a skill creates more than one artifact, create or report a manifest listing artifact paths, command logs, cleanup status, and any generated source files.

---

## Verification

- Prefer the exact command from the approved plan or user request.
- If no command is given, discover project-specific scripts from manifests, task runners, or CI config.
- Use the verification ladder: narrow check -> broader affected-area check -> final full check only when scope/risk justifies it.
- Do not treat generic chained commands as authoritative verification.
- If output is truncated or a command times out, save full output under `/tmp/opencode/b-skills/<skill>/` and inspect the relevant failure section.
- For flaky tests, rerun once; if results differ, report the flake with evidence.
- Use a maximum of 3 local fix/verify iterations for implementation/debug/test work before reporting the remaining evidence and blocker.

---

## Error Handling

- MCP unavailable with documented fallback: warn once and use the fallback.
- MCP unavailable without safe fallback: stop and ask the user to connect or configure it.
- Permission/auth failure: stop and ask for access or an alternate input.
- Large diff or file: summarize scope, then narrow by symbol, path, or user-selected area.
- Stale, partial, or inconsistent tool output must be verified with another source before acting.

---

## Worktree Safety

- Check dirty state before non-trivial edits and preserve unrelated user changes.
- Include relevant untracked non-sensitive files in review or implementation scope; if an untracked file may contain secrets or is unrelated, do not read it without permission.
- If a planned file already contains unrelated edits, read the affected section and patch around those edits.
- If user changes directly conflict with the task, stop and ask how to proceed.

---

## Output Conventions

- Respond in the user's language for chat output. Saved artifacts are English unless requested otherwise.
- Be concise. Lead with the answer/action and reference code as `file_path:line_number`.
- Never auto-add emojis to chat or files unless requested; template emojis are acceptable.
- Use absolute paths in tool calls. Do not run `cd` unless the user asks.
- For implementation, debug, test, refactor, and review tasks, final responses must include: changes/findings, verification evidence, blockers or skipped checks, and the natural next action.

---

## Session Hygiene

- After compaction, re-read the active plan if one exists and prefer focused reads/diff inspection over large file dumps.
- After `/b-plan` approval, the saved plan is the source of truth; use `/b-implement` instead of re-deriving decisions.
- When finishing multi-step work, state what was verified.

---

## Git Safety

Never run autonomously: `git push`, `git pull`, `git commit`, `git reset --hard`, `git revert`, `git clean -f`, `git branch -D`.

Never auto-rollback with `git checkout -- .`; offer it to the user instead.

Never use `--no-verify`, `--no-gpg-sign`, or other hook/sign bypass flags unless explicitly requested. If a hook fails, fix the underlying issue.

---

## Sensitive File Safety

Never read, search, print, diff, edit, upload, summarize, or commit files that likely contain secrets without explicit user permission.

Treat at least these as sensitive:
- `.env*`, `*.env`, `.envrc`, `.npmrc`, `.pypirc`, `.netrc`
- `credentials.json`, `settings.local.json`, `secrets.yml`, `secrets.yaml`, `*.tfvars`, `terraform.tfstate*`
- private keys and cert material: `*.pem`, `*.key`, `*.p12`, `*.pfx`, `id_rsa`, `id_ed25519`, `.ssh/*`, `.gnupg/*`
- cloud / cluster / deploy auth: `.aws/*`, `.config/gcloud/*`, `kubeconfig`, `.kube/config`
- files whose names suggest secrets, tokens, credentials, private keys, or service-account data

Do not recursively grep, glob, or scan sensitive locations without explicit permission.

If unsure whether a file is sensitive, stop and ask first.

Before running `gitnexus analyze`, ensure sensitive and local/generated private artifacts are excluded. If unsure whether indexing is safe, ask first.
