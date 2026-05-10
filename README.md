# b-skills

A lean 8-skill suite for **OpenCode**, optimized around **symbol-first code analysis (Serena MCP)** and **selective structured reasoning (Sequential Thinking only when ambiguity or trade-offs justify it)**.

It follows a symbol-first workflow: **activate project → symbol/file discovery → symbol overview → references → narrow reads → symbolic edits** before any skill trusts code context.

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
| `/b-research` | Decide | All external knowledge — auto-detects quick lookup vs full research for docs, API facts, comparisons, and reports |
| `/b-implement` | Build | Approved-plan execution — apply scoped steps one at a time, verify each step, stop for new decisions |
| `/b-refactor` | Build | Code refactoring — impact analysis, safe mechanical transformation, verify |
| `/b-debug` | Validate | Full-loop debugging — trace, confirm root cause, fix, verify |
| `/b-test` | Validate | TDD — write tests, fix failing tests, evaluate coverage |
| `/b-e2e` | Validate | Browser-based UI testing — navigate, interact, verify visual state, and author Playwright E2E tests |
| `/b-review` | Validate | Pre-PR review — logic, requirements, edge cases, test adequacy |

### Skill graph

```text
                 ┌─────────────┐
                 │  /b-plan    │ ◄── unknown library/approach ──► /b-research
                 └──────┬──────┘
                        │ approved plan
                        ▼
                 /b-implement
                        │
            ┌───────────┼───────────┬──────────────┐
            ▼           ▼           ▼              ▼
      /b-refactor   code edits   /b-test        /b-e2e
            │           │           │              │
            └───────────┴─────┬─────┴──────────────┘
                              ▼
                         /b-review ── READY FOR PR ─► commit
                              │
                         NEEDS FIXES ─► fix → /b-implement or /b-debug

  /b-debug fires any time something breaks at runtime.
  /b-research fires any time a fact, API, or comparison is needed.
```

**Typical flow:**
```text
/b-plan [task] → approve plan → /b-implement → /b-test → /b-review → commit
/b-research [question]  (any time you need docs, API facts, or comparisons)
/b-debug [symptom]      (any time something breaks)
/b-refactor [target]    (mechanical code transformation)
/b-e2e [flow]           (browser UI verification)
```

`/b-plan` supports **quick mode** for scoped daily tasks and **full mode** for unclear, high-risk, or multi-layer work. It owns broad or unclear refactors until they reduce to concrete mechanical steps, at which point `/b-refactor` becomes the safer executor. After the user approves a plan, `/b-implement` is the default executor.

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
| `serena` | Symbol discovery, structure overview, reference tracing, symbol-level edits, and memory — the primary semantic code layer where supported |
| `context7` | Live, version-accurate library docs |
| `brave-search` | Real web search |
| `firecrawl` | Full page scraping, structured data extraction |
| `playwright` | Browser automation, DOM snapshots, and UI interaction for E2E testing |
| `sequential-thinking` | Structured reasoning for multi-hypothesis decisions |

Verify all 6 are connected in OpenCode before relying on the full suite.

---

## Repository maintenance

- `AGENTS.md` is maintainer guidance for working on this source repo locally.
- `global/AGENTS.md` is the runtime rule source installed as `~/.config/opencode/AGENTS.md` by `install.sh`.
- Skills live in `skills/<name>/SKILL.md`.
- Commands live in `commands/<name>.md`.
- `install.sh` is responsible for deploying and pruning suite-managed files under `~/.config/opencode/`.
- Any skill change requires updating both `README.md` and `REFERENCE.md` in the same commit.
- Keep skill descriptions trigger-focused and concise.
- Preserve the existing skill logic; only change platform integration, docs, installer behavior, and OpenCode-specific scaffolding when migrating or maintaining the suite.
