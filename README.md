# b-skills

A lean 9-skill suite for **OpenCode**, optimized around **Serena for symbol-aware code work**, optional **GitNexus graph radar**, and selective reasoning only when ambiguity warrants it.

## Install & Update

```bash
curl -fsSL https://raw.githubusercontent.com/dhoaibao/b-skills/main/install.sh | bash
```

Preview an install without writing into `~/.config/opencode/`:

```bash
curl -fsSL https://raw.githubusercontent.com/dhoaibao/b-skills/main/install.sh | bash -s -- --dry-run
```

The installer deploys this suite into your global OpenCode config directory:
- `~/.config/opencode/skills/`
- `~/.config/opencode/commands/`
- `~/.config/opencode/references/b-skills/`
- `~/.config/opencode/AGENTS.b-skills.md`
- `~/.config/opencode/AGENTS.md` *(only when missing or when you approve replacement)*

If `~/.config/opencode/AGENTS.md` already exists and you do **not** approve replacement, the installer keeps that file, writes the suite snapshot to `AGENTS.b-skills.md`, and exits with an activation-pending status plus next steps. Full suite behavior requires either replacing `AGENTS.md` or manually merging the snapshot into the active file.

This repository is the **install-only source layout** for that deployment. OpenCode does **not** load the checked-in `skills/`, `commands/`, or `references/` directories directly from this repo root; `install.sh` copies them into the correct `~/.config/opencode/` paths.

You can inspect and maintain the suite from this source repository, which contains:
- `AGENTS.md`
- `global/AGENTS.md`
- `references/`
- `skills/`
- `commands/`

---

## Overview

| Skill | Phase | When to use |
|---|---|---|
| `/b-spec` | Clarify | Clarify unclear end states, constraints, acceptance criteria, non-goals, and assumptions before planning or coding |
| `/b-plan` | Decide | Turn a clear non-trivial goal into an execution-ready quick or saved plan |
| `/b-research` | Decide | External knowledge lookup or synthesis with version pinning, source extraction, citation discipline, and news/image routing when needed |
| `/b-implement` | Build | Execute approved or clearly scoped work in coherent verified steps |
| `/b-refactor` | Build | Execute concrete behavior-preserving transforms: rename, extract, move, inline, simplify, or delete |
| `/b-debug` | Validate | Confirm runtime root cause, fix minimally, verify, and remove probes |
| `/b-test` | Validate | Write tests, fix test-only failures, evaluate coverage gaps, and route product bugs out of the test lane |
| `/b-e2e` | Validate | Drive a real browser for flow verification or repo-native browser-test authoring with saved artifacts when evidence or cleanup must be auditable |
| `/b-review` | Validate | Reviewer-style diff/range/audit review focused on blockers, regressions, security, and coverage |

### Typical Flows

```text
/b-spec [rough idea] → /b-plan [scoped task] → approve plan → /b-implement → /b-test → /b-review → commit
/b-spec [underspecified small ask] → /b-implement
/b-test [behavior] → write failing/coverage tests → /b-implement or /b-debug
/b-research [question]  (any time you need docs, API facts, or comparisons)
/b-debug [symptom]      (any time something breaks or is slow)
/b-refactor [target]    (mechanical code transformation)
/b-e2e [flow]           (browser UI verification or browser test authoring)
/b-review --repo-audit [area]  (reviewer-style repository or maintainer audit)
```

`/b-plan` supports **quick mode** for low-risk scoped work and **full mode** for non-trivial work. Skill files now keep only task-specific workflow; shared safety, evidence, artifact, output, and fallback rules live in `global/AGENTS.md`. Routine low-risk runs use happy-path compression, while risky boundaries still trigger the full global discipline.

### Decision boundaries

- `b-spec` vs `b-plan`: use `b-spec` when the end state or acceptance criteria are still unclear; use `b-plan` when the goal is clear but the sequencing or approach is not.
- `b-spec` vs `b-implement`: use `b-implement` when the request is already small, obvious, and implementation-ready.
- `b-plan` vs `b-implement`: use `b-plan` for multi-file or decision-heavy work; use `b-implement` when the change is already scoped and obvious.
- `b-implement` vs `b-refactor`: use `b-refactor` when the primary job is a behavior-preserving rename, extract, move, inline, or delete.
- `b-test` vs `b-debug`: a red test with known-correct product behavior stays in `b-test`; a red test that reveals wrong runtime behavior goes to `b-debug`.
- `b-review` default vs `--repo-audit`: review a diff or range by default; use `--repo-audit` for a reviewer-style pass over a named repository area.

### Runtime conventions

In this source repo, shared runtime rules live in `global/AGENTS.md` and install to `~/.config/opencode/AGENTS.b-skills.md`; the installer replaces the active `AGENTS.md` only when missing or approved. Installed skills still cite `AGENTS.md`, so preserved third-party rules leave the suite activation-pending until merged/replaced.

Runtime headlines: definitions and rubrics (§3), durable plan metadata plus the optional domain-docs convention (§2), MCP bundles and fallbacks (§4), evidence standards including happy-path compression and citation provenance (§5), safety gates plus isolated-workspace preference (§6), execution/verification discipline including skipped-check labels, review checkpoints, transform rollback, cascading failures, and the completion contract (§7), artifacts (§8), output contract including the verbosity cap that exempts BLOCKERs (§9), cross-cutting decisions including the high-risk challenge gate, test-vs-bug routing, DOM/browser and hybrid component boundaries, and the agent-cannot-reproduce protocol (§10), session lifecycle and cross-skill conventions (§11), and the suite-wide common-rationalizations table (§12).

Artifact paths:
- Plans: `.opencode/b-skills/b-plan/<task-slug>.md` after applying the `.opencode/.gitignore` guard in `global/AGENTS.md` §6 (legacy `.opencode/b-plans/` is deprecated). New saved plans include frontmatter for durable approval state, timestamps, approved git HEAD, risk, and touch points. Saved plans remain the canonical repo-local source of truth. `<task-slug>` follows the slug algorithm in `global/AGENTS.md` §8.
- Skill artifacts: `.opencode/b-skills/<skill>/<run-id>/` for repo-local non-sensitive artifacts after applying the `.opencode/.gitignore` guard in `global/AGENTS.md` §6. E2E auth/session state should use the non-worktree path by default. `run-id = <YYYYMMDD-HHMMSS>-<slug>`.
- Saved reports: `.opencode/b-skills/<skill>/<run-id>/report.md` for explicit review/research reports after applying the `.opencode/.gitignore` guard in `global/AGENTS.md` §6.
- Temporary command output: `/tmp/opencode/b-skills/<skill>/<slug>.log`.
- Multi-artifact runs include a `manifest.json` per the schema in `global/AGENTS.md` §8.

Routing/safety highlights: keep one active skill; strict trigger precedence; approved plans are execution source of truth; non-trivial execution prefers isolated workspace/worktree handling when it materially reduces risk; approval gates protect installs, servers, migrations, commits, destructive/shared-environment actions; b-e2e treats production-like targets as read-only by default; generated/lock/snapshot files are derived; manual edits use `apply_patch` with fresh-read, small-hunk, stale-context retry discipline; transform rollback and cascading-failure rules apply across implement/refactor/debug/test; verification narrows before broadening; milestone-sized risky slices can trigger `b-review` before the very end, with the completed step or milestone carried in the handoff; GitNexus is optional radar and Serena is primary hands; cited URLs must come from results actually fetched in the current session; report verbosity is capped per severity but BLOCKERs are never elided; non-trivial runs use the §9 handoff/status schemas and the §7 completion contract. Preserve-mode installs are activation-pending until active `AGENTS.md` is replaced or merged.

### Shared references

The suite ships reusable references to `~/.config/opencode/references/b-skills/` so multiple skills can deepen security, testing, accessibility, performance, and optional domain-glossary conventions without duplicating long lists inside every `SKILL.md`.

See [REFERENCE.md](REFERENCE.md) for detailed skill contracts and maintenance conventions.

---

## Install-only source layout

```text
b-skills/
├── AGENTS.md
├── commands/
│   ├── b-spec.md
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
├── references/
│   ├── accessibility-checklist.md
│   ├── domain-glossary.md
│   ├── performance-checklist.md
│   ├── security-checklist.md
│   └── testing-patterns.md
├── README.md
├── REFERENCE.md
├── install.sh
├── scripts/
│   ├── smoke-install.sh
│   └── validate-skills.sh
└── skills/
    ├── b-spec/SKILL.md
    ├── b-plan/
    │   ├── SKILL.md
    │   └── reference.md          # long-form templates (saved-plan skeleton, quick-plan template, supersede/multi-plan rules)
    ├── b-research/SKILL.md
    ├── b-implement/SKILL.md
    ├── b-refactor/SKILL.md
    ├── b-debug/SKILL.md
    ├── b-test/SKILL.md
    ├── b-e2e/SKILL.md
    └── b-review/SKILL.md
```

Skills are normally a single `SKILL.md`. Optional support files (`reference.md`, `examples.md`, `scripts/`) are added only when externalizing content materially improves maintenance — for example, when a template is long enough to crowd out core instructions under context pressure. See `AGENTS.md` "Skill directory structure template" for the full convention.

This tree is the source repository layout used by `install.sh`, not a directly discoverable OpenCode runtime layout. The installer copies:
- `skills/` → `~/.config/opencode/skills/`
- `commands/` → `~/.config/opencode/commands/`
- `references/` → `~/.config/opencode/references/b-skills/`
- `global/AGENTS.md` → `~/.config/opencode/AGENTS.b-skills.md` and optionally `~/.config/opencode/AGENTS.md`

Installed skill prose references `AGENTS.md`, while this repository keeps the source copy at `global/AGENTS.md`.

When you open this repo in OpenCode, the checked-in `AGENTS.md` provides maintainer guidance for editing the source repository itself.

---

## MCP dependencies

Skills reference **MCP bundles** defined in `global/AGENTS.md` §4 instead of repeating tool lists.

| Bundle | Server | Role |
|---|---|---|
| `serena-symbol-toolkit` | `serena` | Primary hands for symbol discovery, references, diagnostics, and symbol-aware edits. Includes the once-per-session onboarding preflight and the LSP-coverage caveat. |
| `context7-docs` | `context7` | Library/framework docs with a manifests-plus-lockfiles version-pinning rule. |
| `brave-discovery` | `brave-search` | Page discovery only. `brave_news_search` / `brave_image_search` are used inline when a skill explicitly needs news or visual evidence. |
| `firecrawl-extraction` | `firecrawl` | Default tier: `firecrawl_scrape`, `firecrawl_parse`. |
| `firecrawl-extended` | `firecrawl` | Conditional tier: `firecrawl_map`, `firecrawl_extract` for site maps and structured fields. |
| `firecrawl-deep` | `firecrawl` | Last-resort tier: `firecrawl_interact`, `firecrawl_agent`. Cost warning — minutes-scale. **Per-invocation approval by default**; a run-scoped capped pre-authorization may be granted in lieu of per-call asks per `global/AGENTS.md` §4. |
| `playwright-browser` | `playwright` MCP, or local Playwright CLI via `bash` as fallback | Browser automation. `*_unsafe` variants are excluded from the default toolkit and require approval. |
| `gitnexus-radar` *(optional)* | `gitnexus` | Optional graph radar — only when indexed, fresh, and target-aware. Never an edit layer. |

`sequential-thinking` is bundled but optional; use it only when three or more plausible hypotheses have equal cheapest-verification cost. Verify core MCPs before relying on full suite behavior. GitNexus is optional and useful only for indexed repos.

**GitNexus best-practice flow:** install the CLI separately, install MCPs via `install.sh`, index with `gitnexus analyze --skip-agents-md` only after excluding sensitive/private artifacts, and use it only when indexed, fresh, and target-aware. If unavailable/stale/missing target, skills continue with Serena/native tools and label degraded confidence when relevant.

**Decision tree**
- Graph overview / impact / architecture? → GitNexus first (if indexed, fresh, and target-aware).
- Exact symbol / body / symbol edit? → Serena first; `apply_patch` for manual line/prose/config edits.
- GitNexus unavailable / stale / unindexed / missing FTS / missing target? → Warn once, continue with Serena/native tools.

**Using both together**
- GitNexus answers: which subsystem, route, process, consumer set, or contract surface matters.
- Serena answers: which exact symbol/file owns that behavior, what the source says, and what to edit.
- Do not ask both tools the same question. A normal handoff is `GitNexus narrow → Serena inspect/edit`.
- Go back to GitNexus only if Serena reveals a new graph question, such as an unexpected shared boundary or consumer contract.

OpenCode integration: Serena starts without auto-opening the dashboard and owns symbol/reference/structural edits; native tools handle strings, manifests, prose, configs, and commands. Cost-gated tools (`firecrawl-deep`, browser `*_unsafe`) require approval per invocation by default; `firecrawl-deep` additionally supports a run-scoped capped pre-authorization (`global/AGENTS.md` §4). Evidence hierarchy and confidence labeling live in `global/AGENTS.md` §5/§3.

---

## Repository maintenance

- `AGENTS.md` is maintainer guidance for working on this source repo locally.
- `global/AGENTS.md` is the runtime rule source installed as `~/.config/opencode/AGENTS.b-skills.md` by `install.sh`, and optionally applied to the main `~/.config/opencode/AGENTS.md`.
- Skills live in `skills/<name>/SKILL.md`.
- Commands live in `commands/<name>.md`.
- Shared references live in `references/*.md` and install to `~/.config/opencode/references/b-skills/`.
- `install.sh` is responsible for deploying and pruning suite-managed files under `~/.config/opencode/`.
- `scripts/smoke-install.sh` runs isolated installer smoke tests against a temp HOME and repo snapshot.
- `scripts/validate-skills.sh` checks frontmatter, required sections, stale tool names, old artifact paths, GitNexus scope drift, runtime-global leakage, and README/REFERENCE coverage.
- Any skill change requires updating both `README.md` and `REFERENCE.md` in the same commit.
- Run `scripts/validate-skills.sh` before installing or committing skill changes.
- Keep skill descriptions trigger-focused and concise.
- Preserve the existing skill logic; only change platform integration, docs, installer behavior, and OpenCode-specific scaffolding when migrating or maintaining the suite.
