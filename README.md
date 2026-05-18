# b-skills

A lean 9-skill workflow suite for **Claude Code**. It preserves the short `/b-*` skill surface while installing Claude-native skills, agents, hooks, settings, and references into user-level Claude configuration.

## What This Repo Contains

This repository is an install-only source layout. Claude Code does not load the checked-in runtime files directly from this repo root; `install.sh` copies or merges managed assets into `~/.claude/` and optional MCP defaults into `~/.claude.json`.

Primary source paths:

| Path | Purpose |
|---|---|
| `README.md` | Brief repo overview, install commands, and navigation |
| `CLAUDE.md` | Maintainer guidance for editing this source repository |
| `REFERENCE.md` | Reference guide for each skill in the suite |
| `global/CLAUDE.md` | Source for installed always-on Claude memory |
| `skills/` | The 9 user-invocable Claude skills |
| `agents/` | Custom agents for forked planning, research, review, and audit lanes |
| `hooks/` | Claude hook configs and helper scripts, including `hooks/b-skills-guard.py` |
| `settings/` | Managed Claude settings, permissions, hooks, and MCP snippets, including `settings/b-skills.settings.json` |
| `references/` | Shared on-demand references installed under `~/.claude/references/b-skills/` |

## Install

Install or update b-skills-managed Claude config:

```bash
curl -fsSL https://raw.githubusercontent.com/dhoaibao/b-skills/main/install.sh | bash
```

Preview the install without writing into `~/.claude/` or `~/.claude.json`:

```bash
curl -fsSL https://raw.githubusercontent.com/dhoaibao/b-skills/main/install.sh | bash -s -- --dry-run
```

Uninstall b-skills-managed files:

```bash
curl -fsSL https://raw.githubusercontent.com/dhoaibao/b-skills/main/install.sh | bash -s -- --uninstall
```

The installer deploys or merges:

| Source | Runtime target |
|---|---|
| `global/CLAUDE.md` | `~/.claude/CLAUDE.md` and `~/.claude/b-skills/CLAUDE.md` snapshot |
| `skills/` | `~/.claude/skills/` |
| `agents/` | `~/.claude/agents/` |
| `hooks/` | `~/.claude/hooks/` |
| `references/` | `~/.claude/references/b-skills/` |
| `settings/b-skills.settings.json` | merged into `~/.claude/settings.json` |
| optional MCP defaults | merged into `~/.claude.json` |

If `~/.claude/CLAUDE.md` already exists and replacement is not approved, the installer preserves it, writes the suite snapshot to `~/.claude/b-skills/CLAUDE.md`, and exits activation-pending so you can merge intentionally.

The phase 1 Claude-native installer does not migrate OpenCode-only custom provider settings or remove a previous `~/.config/opencode/` installation.

## Skills

| Skill | Phase | Use it for |
|---|---|---|
| `b-spec` | Clarify | Lock unclear outcomes, constraints, acceptance criteria, non-goals, and assumptions |
| `b-plan` | Decide | Turn a clear goal into ordered implementation steps or a saved plan |
| `b-research` | Decide | Fetch external docs, API facts, release notes, comparisons, or recency-sensitive evidence |
| `b-implement` | Build | Execute approved or clearly scoped work in coherent verified steps |
| `b-refactor` | Build | Rename, extract, move, inline, simplify, or delete while preserving behavior |
| `b-debug` | Validate | Diagnose runtime failures, confirm root cause, fix minimally, and verify |
| `b-test` | Validate | Write tests, fix test-only failures, evaluate coverage, and handle TDD flows |
| `b-review` | Validate | Review changed-code diffs, ranges, or checkpoints for bugs and regressions |
| `b-audit` | Validate | Audit a named repository area, runtime contract, installer, validator, or suite surface |

Typical flow:

```text
/b-spec -> /b-plan -> approve plan -> /b-implement -> /b-test -> /b-review
```

Use `/b-research`, `/b-debug`, `/b-refactor`, or `/b-audit` directly when the task already matches that lane. See [REFERENCE.md](REFERENCE.md) for the detailed skill guide.

## References

Shared reference files install to `~/.claude/references/b-skills/`:

| Reference | Purpose |
|---|---|
| `runtime-contract.md` | Detailed schemas, rubrics, MCP bundles, fallback ladder, artifacts, and edge-case protocols |
| `domain-glossary.md` | Optional project glossary convention for terminology and bounded-context planning |
| `performance-checklist.md` | Multi-layer slowdown triage checklist used by debug, review, and audit lanes |

Maintainer rules for editing skill files, frontmatter, docs sync, MCP bundle references, and validation live in [CLAUDE.md](CLAUDE.md). Run `scripts/validate-skills.sh` before installing or committing suite changes.
