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
| `/b-plan` | Decide | Think before coding — quick/full planning, task decomposition, approach evaluation, plan file when needed |
| `/b-research` | Decide | All external knowledge — quick lookup vs full research with source-quality gating |
| `/b-implement` | Build | Approved/scoped-plan execution — apply scoped steps one at a time, verify each step, stop for new decisions |
| `/b-refactor` | Build | Code refactoring — impact analysis, safe mechanical transformation, verify |
| `/b-debug` | Validate | Full-loop debugging — trace, confirm root cause, fix, verify |
| `/b-test` | Validate | TDD — write tests, fix failing tests, evaluate coverage with full failure-output capture |
| `/b-e2e` | Validate | Browser-based UI testing — manage state, navigate, verify responsive UI, and author Playwright E2E tests |
| `/b-review` | Validate | Pre-PR changed-code review — logic, requirements, edge cases, security, test adequacy |

### Typical Flows

```text
/b-plan [task] → approve plan → /b-implement → /b-test → /b-review → commit
/b-test [behavior] → write failing/coverage tests → /b-implement or /b-debug
/b-research [question]  (any time you need docs, API facts, or comparisons)
/b-debug [symptom]      (any time something breaks)
/b-refactor [target]    (mechanical code transformation)
/b-e2e [flow]           (browser UI verification)
```

`/b-plan` supports **quick mode** for scoped daily tasks and **full mode** for unclear, high-risk, or multi-layer work. It owns broad or unclear refactors until they reduce to concrete mechanical steps, at which point `/b-refactor` becomes the safer executor. After the user approves a plan, `/b-implement` is the default executor.

### Runtime conventions

- Plans are saved to `.opencode/b-plans/<task-slug>.md`.
- Skill artifacts are saved to `.opencode/b-skills/<skill>/<run-id>/`; E2E artifacts use `.opencode/b-skills/b-e2e/<run-id>/`, where `run-id` is `<YYYYMMDD-HHMMSS>-<slug>`.
- Temporary command output uses `/tmp/opencode/b-skills/<skill>/<slug>.log`.
- Skills that create multiple artifacts report or maintain a manifest with artifact paths, generated files, command logs, and cleanup status.
- Cross-skill handoffs use a compact payload: `source`, `scope`, `files`, `commands`, `blockers`, and `next skill`.
- Keep one active skill until its stop condition is hit; do not bounce across skills for optional enrichment or minor lookups that the current skill can finish inline.
- Approval is required before installs, dev servers, migrations, production-like/staging writes, broad refactors, commits, or destructive commands.
- Manual edits use `apply_patch`; skill instructions should not rely on unavailable native `edit` or `write` tools.
- Use the lightest capable tool for the evidence needed. Native tools stay first for exact strings, manifests, prose, configs, and small reads; MCPs are for semantic or external tasks that materially reduce ambiguity.
- Verification commands are discovered from project scripts/CI first. The default ladder is narrow check → broader affected-area check → full check only when scope/risk justifies it.
- Full research ranks sources as official docs/changelogs, source repos/releases, vendor engineering posts, reputable community sources, then snippets/SEO content.
- GitNexus is optional radar; Serena is primary hands. GitNexus scopes graph risk, while Serena confirms exact symbols and performs symbol-aware edits.

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

| MCP | Role |
|---|---|
| `serena` | Symbol discovery, declaration/implementation lookup, code-pattern search, file diagnostics, reference tracing, symbol-level edits, and memory — the primary semantic code layer where supported |
| `context7` | Live, version-accurate library docs |
| `brave-search` | Real web search, news lookups, and optional visual-reference discovery |
| `firecrawl` | Full page scraping, local document parsing, structured extraction, JS follow-up interaction, and deep research fallback |
| `playwright` | Browser automation, DOM snapshots, advanced UI interaction, network/console inspection, and Playwright E2E authoring |
| `sequential-thinking` | Structured reasoning for multi-hypothesis decisions |
| `gitnexus` *(optional)* | Radar for graph-level repo intelligence: cross-file impact, architecture context, execution-flow discovery, route/API consumers, response-shape checks, tool maps, and multi-repo mapping — only useful when indexed and fresh |

Verify the **6 core MCPs** are connected in OpenCode before relying on the full suite. GitNexus is optional and augments the suite when a repo has been indexed.

**GitNexus best-practice flow:**
1. Install the GitNexus CLI separately (`npm install -g gitnexus` or your preferred method).
2. Run `install.sh` with `B_SKILLS_INSTALL_MCP=Y` (or answer `y` at the MCP prompt) — GitNexus is included in the default MCP set.
3. Index each repo with `gitnexus analyze` only after sensitive files and local private artifacts are excluded.
4. Use GitNexus only when the repo is indexed, fresh, and the target file/symbol is represented.
5. Selected skills reach for GitNexus first when the task is graph-shaped (architecture, blast radius, changed scope); if GitNexus is unavailable, stale, unindexed, missing FTS, or missing the target, they warn once and continue with Serena and native tools.

**Decision tree**
- Graph overview / impact / architecture? → GitNexus first (if indexed, fresh, and target-aware).
- Exact symbol / body / symbol edit? → Serena first; `apply_patch` for manual line/prose/config edits.
- GitNexus unavailable / stale / unindexed / missing FTS / missing target? → Warn once, continue with Serena/native tools.

**Using both together**
- GitNexus answers: which subsystem, route, process, consumer set, or contract surface matters.
- Serena answers: which exact symbol/file owns that behavior, what the source says, and what to edit.
- Do not ask both tools the same question. A normal handoff is `GitNexus narrow -> Serena inspect/edit`.
- Go back to GitNexus only if Serena reveals a new graph question, such as an unexpected shared boundary or consumer contract.

OpenCode integration:
- Serena runs as `serena start-mcp-server --context=ide --project-from-cwd`.
- Serena owns symbol discovery, references, and structural edits; native tools handle files, strings, manifests, commands, prose, and configs.
- Serena preflight (`check_onboarding_performed` → `onboarding` if needed) should happen once when symbol-aware work starts, not before every later Serena step in the same run.
- Serena tools adopted in this suite: `find_declaration`, `find_implementations`, `search_for_pattern`, and `get_diagnostics_for_file` for tighter navigation, fuzzy code discovery, and narrow local verification.
- Firecrawl is now used beyond scrape/search: `firecrawl_parse` for local docs, `firecrawl_interact` for JS-heavy known pages, and `firecrawl_agent` only as a last-resort deep-research fallback.
- Playwright guidance now covers uploads, dialogs, dropdowns, drag/drop, and multi-tab flows, while keeping `playwright_browser_run_code_unsafe` as a strict last resort.
- GitNexus guidance now includes API-aware tools such as `api_impact`, `shape_check`, `route_map`, and `tool_map` where route or tool contracts are the real risk surface.
- GitNexus augments Serena for graph-level intelligence only when indexed, fresh, and target-aware.

**Evidence model:** GitNexus evidence scopes graph risk; Serena evidence confirms exact symbols and references; text search confirms strings/config/prose; runtime checks verify behavior.

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
