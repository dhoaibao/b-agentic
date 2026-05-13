# b-skills

A lean 8-skill suite for **OpenCode**, optimized around **Serena for symbol-aware code work**, optional **GitNexus graph radar**, and selective reasoning only when ambiguity warrants it.

## Install & Update

```bash
curl -fsSL https://raw.githubusercontent.com/dhoaibao/b-skills/main/install.sh | bash
```

The installer deploys this suite into your global OpenCode config directory:
- `~/.config/opencode/skills/`
- `~/.config/opencode/commands/`
- `~/.config/opencode/AGENTS.md`

This repository is the **install-only source layout** for that deployment. OpenCode does **not** load the checked-in `skills/` or `commands/` directories directly from this repo root; `install.sh` copies them into the correct `~/.config/opencode/` paths.

You can inspect and maintain the suite from this source repository, which contains:
- `AGENTS.md`
- `global/AGENTS.md`
- `skills/`
- `commands/`

---

## Overview

| Skill | Phase | When to use |
|---|---|---|
| `/b-plan` | Decide | Clarify scope, choose an approach, and produce an execution-ready plan when the work is broad, unclear, or risky |
| `/b-research` | Decide | External knowledge — lookup or research with citation discipline; auto-deepens, never asks the user to pick a mode |
| `/b-implement` | Build | Execute approved or clearly scoped work one step at a time, verify each step, and stop for new decisions |
| `/b-refactor` | Build | Concrete behavior-preserving transforms — rename, extract, move, inline, or delete dead code |
| `/b-debug` | Validate | Runtime bug ownership — trace, confirm root cause, fix minimally, verify; handles errors, races, perf regressions, and cannot-reproduce reports |
| `/b-test` | Validate | Code-level tests — write tests, fix test-only failures, or review coverage gaps without confusing them with runtime bugs |
| `/b-e2e` | Validate | Live browser verification and browser-test authoring, while respecting the repo's existing E2E framework |
| `/b-review` | Validate | Pre-PR changed-code review, or an explicitly requested repository audit, focused on blockers, regressions, security, and missing coverage |

### Typical Flows

```text
/b-plan [task] → approve plan → /b-implement → /b-test → /b-review → commit
/b-test [behavior] → write failing/coverage tests → /b-implement or /b-debug
/b-research [question]  (any time you need docs, API facts, or comparisons)
/b-debug [symptom]      (any time something breaks or is slow)
/b-refactor [target]    (mechanical code transformation)
/b-e2e [flow]           (browser UI verification or browser test authoring)
/b-review --repo-audit [area]  (reviewer-style repository or maintainer audit)
```

`/b-plan` supports **quick mode** for trivial scoped tasks and **full mode** for non-trivial work. It owns broad or unclear refactors until they reduce to concrete mechanical steps, at which point `/b-refactor` becomes the safer executor. After plan approval, `/b-implement` is the default executor for multi-step work.

### Runtime conventions

All shared rules live in `global/AGENTS.md`. The headlines:

- **Definitions** (`§3`): "non-trivial", **small direct request** (≤3 files), **severity** (BLOCKER/MAJOR/MINOR/NIT), **risk** (trivial/low/medium/high), and the **confidence signal** every partial-evidence answer carries.
- **MCP bundles** (`§4`): skills reference named bundles — `serena-symbol-toolkit`, `gitnexus-radar`, `context7-docs`, `brave-discovery`, `firecrawl-extraction` / `firecrawl-extended` / `firecrawl-deep`, `playwright-browser`. Bundle definitions own session-init, fallback ladder, language-coverage caveats, and cost/approval gates.
- **Tool-budget review gate** (`§4`): around the 12th MCP call, emit a one-line notice and reassess; continue only within the same active thread, and ask before starting a new tool-heavy thread or pushing past the hard review gate.
- **Safety gates** (`§6`): privacy gate, sensitive-file safety, worktree safety, git safety, and the **canonical approval ask** template.
- **Iteration cap** (`§7`): maximum of 3 fix/verify loops per step before surfacing the blocker.
- **Empty-state defaults** (`§7`): explicit defaults for missing diff, missing plan, missing framework, or unavailable MCPs.
- **Artifacts** (`§8`): canonical slug algorithm, run-id format, plan path, manifest schema.
- **Output contract** (`§9`): chat language vs artifact language, **skill-exit status block**, and **handoff envelope**.
- **Test-vs-bug decision** (`§10`): the single home for "is this a test problem or a real bug?" — owned in global, referenced by `b-test` and `b-debug`. Also owns the DOM-unit vs browser-flow boundary and the self-review vs external-review distinction.
- **Session lifecycle** (`§11`): preflight and crash/resume rules.

Artifact paths:
- Plans: `.opencode/b-skills/b-plan/<task-slug>.md` (legacy `.opencode/b-plans/` is deprecated). Saved plans remain the canonical repo-local source of truth even when non-plan runtime artifacts would fall back to `~/.config/opencode/...` or `/tmp/opencode/...`. `<task-slug>` follows the slug algorithm in `global/AGENTS.md` §8.
- Skill artifacts: `.opencode/b-skills/<skill>/<run-id>/` for repo-local non-sensitive artifacts when `.opencode/` is already git-ignored; otherwise use `~/.config/opencode/b-skills/<skill>/<run-id>/` or `/tmp/opencode/b-skills/<skill>/<run-id>/`. E2E auth/session state should use the non-worktree path by default. `run-id = <YYYYMMDD-HHMMSS>-<slug>`.
- Temporary command output: `/tmp/opencode/b-skills/<skill>/<slug>.log`.
- Multi-artifact runs include a `manifest.json` per the schema in `global/AGENTS.md` §8.

Routing and safety highlights:
- Keep one active skill until its stop condition is hit; do not bounce across skills for optional enrichment.
- Trigger precedence is strict: browser flow → `/b-e2e`; DOM-rendered unit test → `/b-test`; likely product bug → `/b-debug`; named behavior-preserving transform → `/b-refactor`; unclear scope → `/b-plan`; external-knowledge blocker → `/b-research`.
- After `/b-plan` approval, the approved plan becomes the execution source of truth, subject to the **plan staleness gate** and **plan revision protocol** in `global/AGENTS.md` §2.
- Approval is required before installs, dev servers, migrations, production-like/staging writes, broad refactors, commits, or destructive commands — using the **canonical approval ask** template in `global/AGENTS.md` §6.
- Manual edits use `apply_patch`.
- Verification follows the ladder: narrow check → broader affected-area check → full check only when scope or risk justifies it.
- GitNexus is optional radar; Serena is primary hands.
- Cross-skill handoffs use the **handoff envelope** in `global/AGENTS.md` §9.
- Non-trivial skill runs close with the **skill-exit status block** in `global/AGENTS.md` §9.

See [REFERENCE.md](REFERENCE.md) for detailed skill contracts and maintenance conventions.

---

## Install-only source layout

```text
b-skills/
├── AGENTS.md
├── commands/
│   ├── b-plan.md
│   ├── b-research.md
│   ├── b-implement.md
│   ├── b-refactor.md
│   ├── b-debug.md
│   ├── b-test.md
│   ├── b-e2e.md
│   └── b-review.md
├── global/
│   └── AGENTS.md
├── README.md
├── REFERENCE.md
├── install.sh
├── scripts/
│   └── validate-skills.sh
└── skills/
    ├── b-plan/SKILL.md
    ├── b-research/SKILL.md
    ├── b-implement/SKILL.md
    ├── b-refactor/SKILL.md
    ├── b-debug/SKILL.md
    ├── b-test/SKILL.md
    ├── b-e2e/SKILL.md
    └── b-review/SKILL.md
```

This tree is the source repository layout used by `install.sh`, not a directly discoverable OpenCode runtime layout. The installer copies:
- `skills/` → `~/.config/opencode/skills/`
- `commands/` → `~/.config/opencode/commands/`
- `global/AGENTS.md` → `~/.config/opencode/AGENTS.md`

When you open this repo in OpenCode, the checked-in `AGENTS.md` provides maintainer guidance for editing the source repository itself.

---

## MCP dependencies

Skills reference **MCP bundles** defined in `global/AGENTS.md` §4 rather than enumerating individual tool names.

| Bundle | Server | Role |
|---|---|---|
| `serena-symbol-toolkit` | `serena` | Primary hands for symbol discovery, references, diagnostics, and symbol-aware edits. Includes the once-per-session onboarding preflight and the LSP-coverage caveat. |
| `context7-docs` | `context7` | Library/framework docs with a manifests-plus-lockfiles version-pinning rule. |
| `brave-discovery` | `brave-search` | Page discovery only. `brave_news_search` / `brave_image_search` are used inline when a skill explicitly needs news or visual evidence. |
| `firecrawl-extraction` | `firecrawl` | Default tier: `firecrawl_scrape`, `firecrawl_parse`. |
| `firecrawl-extended` | `firecrawl` | Conditional tier: `firecrawl_map`, `firecrawl_extract` for site maps and structured fields. |
| `firecrawl-deep` | `firecrawl` | Last-resort tier: `firecrawl_interact`, `firecrawl_agent`. Cost warning — minutes-scale, **requires explicit user approval per invocation**. |
| `playwright-browser` | `playwright` MCP, or local Playwright CLI via `bash` as fallback | Browser automation. `*_unsafe` variants are excluded from the default toolkit and require approval. |
| `gitnexus-radar` *(optional)* | `gitnexus` | Optional graph radar — only when indexed, fresh, and target-aware. Never an edit layer. |

`sequential-thinking` is **bundled but optional**. The default MCP install includes it, but it remains an escape hatch rather than a routine dependency; invoke it only when three or more plausible hypotheses remain with equal cheapest-verification cost.

Verify the core MCPs are connected in OpenCode before relying on the full suite. GitNexus is optional and augments the suite when a repo has been indexed.

**GitNexus best-practice flow:**
1. Install the GitNexus CLI separately (`npm install -g gitnexus` or your preferred method).
2. Run `install.sh` with `B_SKILLS_INSTALL_MCP=Y` (or answer `y` at the MCP prompt) — GitNexus is included in the default MCP set.
3. Index each repo with `gitnexus analyze --skip-agents-md` only after sensitive files and local private artifacts are excluded.
4. Use GitNexus only when the repo is indexed, fresh, and the target file/symbol is represented.
5. Selected skills reach for GitNexus first when the task is graph-shaped (architecture, blast radius, changed scope); if GitNexus is unavailable, stale, unindexed, missing FTS, or missing the target, they warn once and continue with Serena and native tools, tagged `[degraded: gitnexus unavailable]`.

**Decision tree**
- Graph overview / impact / architecture? → GitNexus first (if indexed, fresh, and target-aware).
- Exact symbol / body / symbol edit? → Serena first; `apply_patch` for manual line/prose/config edits.
- GitNexus unavailable / stale / unindexed / missing FTS / missing target? → Warn once, continue with Serena/native tools.

**Using both together**
- GitNexus answers: which subsystem, route, process, consumer set, or contract surface matters.
- Serena answers: which exact symbol/file owns that behavior, what the source says, and what to edit.
- Do not ask both tools the same question. A normal handoff is `GitNexus narrow → Serena inspect/edit`.
- Go back to GitNexus only if Serena reveals a new graph question, such as an unexpected shared boundary or consumer contract.

OpenCode integration:
- Serena runs as `serena start-mcp-server --context=ide --project-from-cwd`.
- Serena owns symbol discovery, references, and structural edits; native tools handle files, strings, manifests, commands, prose, and configs.
- Serena preflight is a session-level concern owned by `global/AGENTS.md` §4 — it runs once when symbol-aware work first becomes necessary, not before every later Serena step in the same run.
- GitNexus augments Serena for graph-level intelligence only when indexed, fresh, and target-aware. Bundle definition and freshness gate live in `global/AGENTS.md` §4.
- Cost-gated tools (`firecrawl-deep`, browser `*_unsafe` variants) require explicit user approval per invocation.

**Evidence model:** runtime evidence outranks graph evidence; Serena confirms exact symbols and references; text search confirms strings, config, and prose; web/search snippets are weakest and must be backed by fetched sources when confidence matters. Any answer derived from incomplete evidence carries the **confidence signal** defined in `global/AGENTS.md` §3.

---

## Repository maintenance

- `AGENTS.md` is maintainer guidance for working on this source repo locally.
- `global/AGENTS.md` is the runtime rule source installed as `~/.config/opencode/AGENTS.md` by `install.sh`.
- Skills live in `skills/<name>/SKILL.md`.
- Commands live in `commands/<name>.md`.
- `install.sh` is responsible for deploying and pruning suite-managed files under `~/.config/opencode/`.
- `scripts/validate-skills.sh` checks frontmatter, required sections, stale tool names, old artifact paths, GitNexus scope drift, runtime-global leakage, and README/REFERENCE coverage.
- Any skill change requires updating both `README.md` and `REFERENCE.md` in the same commit.
- Run `scripts/validate-skills.sh` before installing or committing skill changes.
- Keep skill descriptions trigger-focused and concise.
- Preserve the existing skill logic; only change platform integration, docs, installer behavior, and OpenCode-specific scaffolding when migrating or maintaining the suite.
