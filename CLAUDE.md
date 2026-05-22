# b-agentic - Claude Code Runtime Authoring

Guidelines for creating, editing, and maintaining the Claude Code native `b-agentic` workflow kernel in this repository.

## Scope

- This file is the Claude Code maintainer guidance for the source repository.
- Claude Code is the reference runtime. Do not preserve OpenCode behavior as a product requirement unless a new plan explicitly asks for migration compatibility.
- Keep root docs targeted: `README.md` is the brief repo overview, root `CLAUDE.md` is maintainer guidance for this repo, and `REFERENCE.md` is the reference guide for each skill.
- Runtime behavior lives in `runtimes/claude-code/kernel.md` (kernel installed as `~/.claude/CLAUDE.md`), `references/contract/` (detailed contract), and `skills/*/SKILL.md` (Claude skills).
- `install.sh` deploys runtime files to `~/.claude/`, installs each skill under `~/.claude/skills/<name>/`, copies shared references into each skill as supporting files, and replaces `~/.claude/CLAUDE.md` only when missing or approved.
- When authoring runtime-facing skill prose, references to `CLAUDE.md` mean the active runtime kernel installed from `runtimes/claude-code/kernel.md`, not this source-repo maintainer guide. Long-form schemas, rubrics, and edge-case protocols live in `references/contract/`; when a skill depends on one of them, phrase the instruction as a required read gate using the installed skill support path `${CLAUDE_SKILL_DIR}/references/b-agentic/contract/<section-file>.md`.
- Runtime conformance depends on explicit read gates plus the runtime gate checklist, not passive reminders. Keep those gates local to the step that uses the shared schema, checklist, or protocol.

## Quick Links

- `skills/b-orchestrate/SKILL.md` - coordinate full PR-readiness workflows across phase skills
- `skills/b-plan/SKILL.md` - task decomposition and planning
- `skills/b-research/SKILL.md` - library docs and multi-source research
- `skills/b-implement/SKILL.md` - approved-plan execution
- `skills/b-refactor/SKILL.md` - behavior-preserving code transforms
- `skills/b-debug/SKILL.md` - hypothesis-driven debugging
- `skills/b-test/SKILL.md` - test writing, coverage, and test-only failures
- `skills/b-browser/SKILL.md` - browser/DOM/visual/e2e evidence
- `skills/b-review/SKILL.md` - pre-PR changed-code review
- `skills/b-audit/SKILL.md` - b-agentic suite self-audits (suite-only)
- `skills/b-ship/SKILL.md` - commit, push, and open PR after READY FOR PR
- `references/` - reusable checklists and the detailed runtime contract
- `runtimes/claude-code/kernel.md` - runtime kernel source
- `runtimes/claude-code/configs/` - Claude Code settings and MCP templates

## Claude Skill Frontmatter

Every `skills/<name>/SKILL.md` must begin with YAML frontmatter:

```yaml
---
name: b-skill-name
description: >
  [Trigger-focused description, <=80 words. Answer only: when should Claude
  Code load or list this skill? Include the ALWAYS trigger condition and one
  sentence distinguishing this from similar skills.]
argument-hint: "[optional arguments]"
---
```

Required fields:
- `name` - kebab-case, prefixed with `b-`, matching the directory name.
- `description` - trigger-focused and concise; the combined `description` plus `when_to_use` text should stay comfortably below Claude Code's listing cap.

Supported optional fields used by this repo:
- `argument-hint` - concise autocomplete help for user-invocable skills.
- `when_to_use` - only when the description needs extra matching context.
- `user-invocable` - use only when a skill is background knowledge and should be hidden from the slash menu.
- `context` and `agent` - use only for approved forked-subagent skills.
- `paths` - use only when a skill should activate for specific file globs.
- `shell` - use only when a skill intentionally uses Claude Code dynamic shell context.

Repo conventions:
- Do not use legacy OpenCode-only compatibility or suite metadata fields.
- All skills are model-invocable when their descriptions match the request.

## Skill Directory Structure

```text
skills/<name>/
├── SKILL.md           # Main Claude skill instructions (required)
├── reference.md       # Detailed skill-local reference (optional)
├── examples.md        # Usage examples (optional)
└── scripts/           # Utility scripts (optional)
```

Claude Code exposes each skill directory as `/b-*` after install. The old command-wrapper directory is removed because Claude skills create slash commands directly.

Use supporting files when they materially improve token hygiene. Reference them from `SKILL.md` with `${CLAUDE_SKILL_DIR}/...` so they work from personal-global installs, project installs, and plugin packaging.

## Shared References

Top-level `references/*.md` files are allowed when two or more skills need the same checklist or pattern guidance.

- Keep them short, task-oriented, and reusable across skills.
- They may define optional conventions, such as glossary/domain-doc layouts, when adding a whole new skill would be overkill.
- `install.sh` copies shared references to `~/.claude/b-agentic/references/` and to each installed skill under `references/b-agentic/`.
- Treat reference-file changes like runtime-facing guidance: keep `README.md` and `REFERENCE.md` aligned in the same commit.

## Skill File Structure Template

```markdown
---
name: b-example
description: >
  [<=80 words, intent + disambiguation. Do not include long trigger keyword
  lists; those live in CLAUDE.md and maintainer docs.]
argument-hint: "[input]"
---

# b-example

$ARGUMENTS

[1-2 sentence summary of what this skill does and why it exists.]

## When to use
- [Scenario]

## When NOT to use
- [Scenario that should trigger a different skill]

## Tools required
- `bundle-name` (see `CLAUDE.md` §4)

Tool fallback rules are centralized in the kernel; skills do not restate them.

## Steps

### Step 1 - [Name]
[Imperative instructions. Every step must have action verbs.]

## Output format
[Template or example]

## Rules
- [Task-specific constraints only; shared schemas live in CLAUDE.md or the runtime contract.]
```

## MCP Selection Criteria

Skills declare MCP usage by referencing bundles summarized in `runtimes/claude-code/kernel.md` §4 and fully defined in `references/contract/` §4. Do not enumerate per-tool MCP lists inside skills. Native tools such as Glob/Grep/Read/Bash are not MCP bundles and may be listed separately when useful.

MCP user-scope configuration lives in `runtimes/claude-code/configs/mcp.user.template.json`. The installer copies templates to `~/.claude/b-agentic/templates/` and merges the user-scope MCP set into `~/.claude.json` during the normal one-command install. The global MCP set contains Serena, Context7, Brave Search, Firecrawl, Playwright, and GitNexus; runtime skills still use MCP lazily by evidence need. Keep MCP template changes documented in `runtimes/claude-code/configs/README.md` and `README.md`, and covered by `scripts/validate-skills.sh` plus `scripts/smoke-install.sh`.

Rules:
- Never add a bundle just to increase coverage; every bundle must have a clear use case in the Steps section.
- Reference the bundle name. The bundle definition owns session-init steps, fallback behavior, cost/approval caveats, and language-coverage caveats.
- Label each bundle in "Tools required" with its role when it is conditional.
- Tool fallback rules are centralized in the kernel (see `runtimes/claude-code/kernel.md` §4); skills do not restate graceful degradation lines.
- Prefer the lightest capable tool. Do not force MCP-first behavior for exact strings, manifests, prose, small file reads, or other cases where native tools are cheaper and equally reliable.
- Do not list unsafe tool variants in skill workflows; approval is required per invocation.
- Do not commit API keys or secret-looking placeholders in MCP templates. Use Claude Code environment expansion such as `${CONTEXT7_API_KEY:-}`, `${BRAVE_API_KEY}`, and `${FIRECRAWL_API_KEY}` in templates; installer prompts may write user-provided keys only to user-scope `~/.claude.json`.

GitNexus-specific criteria:
- GitNexus is always optional radar. It is never a primary dependency and never acts as the editing layer.
- Serena is primary hands for exact symbol discovery, source inspection, references, and symbol-aware edits.
- Add `gitnexus-radar` only when graph-level intelligence materially improves the workflow.
- If the target symbol or file is already known, or the task is local to a single file/module, skip GitNexus and go straight to Serena or native tools.

## File Sync Rules

All skills live in `skills/<name>/SKILL.md`. When changing skill files:

| Change type | Action |
|---|---|
| Create skill | Create `skills/<name>/SKILL.md` and optional supporting files |
| Update skill | Edit `skills/<name>/SKILL.md`; update supporting files only when they improve token hygiene |
| Delete skill | Delete `skills/<name>/SKILL.md`, optional supporting files, and the directory if empty |

Runtime contract sync:
- When always-on runtime behavior changes, update `runtimes/claude-code/kernel.md`.
- When detailed schemas/rubrics/protocols change, update `references/contract/`.
- Keep related repo docs aligned in the same commit.

Root `CLAUDE.md` remains maintainer guidance for this source repository.

## Runtime Adapters

Each supported runtime has its own adapter directory under `runtimes/<name>/`. The adapter holds delivery artifacts for that runtime only. Skills and shared references live outside `runtimes/`, but today their content is authored against the Claude Code kernel and uses Claude-Code conventions (`${CLAUDE_SKILL_DIR}`, `~/.claude/...`, `/tmp/claude-code/...`). A real second adapter would need to either accept those conventions or re-template the shared content; treat "runtime-agnostic" as a layout property, not a content property.

### Adapter directory structure

```text
runtimes/<name>/
├── kernel.md      # Always-on runtime rules (installed as the runtime's memory/context file)
└── configs/       # Runtime-specific config templates (settings, MCP, etc.)
```

Currently only `claude-code` exists end-to-end. Do not create adapters for other runtimes without an approved plan.

### What is wired today vs. what is still TODO

`install.sh` parameterises only the **source** side of the adapter: `--runtime=<name>` and `B_AGENTIC_RUNTIME` resolve `KERNEL_SRC` and `TEMPLATES_SRC` from `runtimes/$RUNTIME/...`, and the name is validated against path traversal. `scripts/validate-skills.sh` enforces the `kernel.md` invariant for every `runtimes/*/` directory.

Destinations and validator policy are still Claude-Code-specific:

- Destination paths (`~/.claude/CLAUDE.md`, `~/.claude/skills/`, `~/.claude/b-agentic/`), env-var defaults (`B_AGENTIC_CLAUDE_DIR`, `B_AGENTIC_CLAUDE_JSON`), and merge targets (`~/.claude/settings.json`, `~/.claude.json` user scope) are all hard-coded for Claude Code in `install.sh`.
- `scripts/validate-skills.sh` requires Claude-Code-specific markers in `references/contract/index.md` (`${CLAUDE_SKILL_DIR}/references/b-agentic/contract/`, `~/.claude/b-agentic`, `/tmp/claude-code/b-agentic`), in `runtimes/claude-code/configs/README.md`, and in the kernel itself.

Running `install.sh --runtime=<other>` today would still write into Claude Code paths.

### Adding a new runtime adapter

1. Create `runtimes/<name>/` with at least `kernel.md`.
2. Add `configs/` (and a per-adapter `configs/README.md`) when the runtime needs config templates.
3. Update `install.sh` so destination paths, env-var overrides, settings/MCP merge targets, and the manifest layout are selected by `$RUNTIME` instead of hard-coded to Claude Code.
4. Generalise `scripts/validate-skills.sh` so its Claude-Code-only markers (contract index paths, configs/README invariant, kernel markers) are scoped per adapter or made adapter-aware.
5. Either keep skill and shared-reference content Claude-Code-shaped (and document that constraint), or re-template the Claude-Code-specific paths/env-vars out of shared content for the new adapter.
6. Update `README.md`, `CLAUDE.md`, and `REFERENCE.md` in the same commit.

### Runtime file sync rule

When always-on runtime behavior changes, update `runtimes/<name>/kernel.md`. When runtime config templates change, update `runtimes/<name>/configs/`. Keep `README.md` and `CLAUDE.md` aligned in the same commit.

## Doc Sync Rule

Any change to a skill file requires updating both `README.md` and `REFERENCE.md` in the same commit.

| Change type | README.md | REFERENCE.md |
|---|---|---|
| Create skill | Add row to skills overview table | Add full reference section |
| Update skill | Update the skill overview and install/source-layout notes if changed | Rewrite the skill's reference section to match |
| Delete skill | Remove the skill from overview/source-layout docs | Remove the skill's reference section |

Never leave README or REFERENCE out of sync with a skill file change.

## Quality Checklist

Before merging any skill file change, verify:

1. Description <=80 words.
2. Every step uses imperative verbs.
3. Fallbacks are explicit without duplicating global MCP fallback rules.
4. Inter-skill handoffs have trigger conditions and resume expectations.
5. No trigger keyword regression.
6. `scripts/validate-skills.sh` passes.
7. No avoidable churn or repeated preflights.
8. Token hygiene is preserved.
9. No duplicated global concepts from `CLAUDE.md` or `references/contract/`.
10. Reference gates are explicit at the point of use.
11. Runtime enforcement is preserved through `runtimes/claude-code/kernel.md`, skill read gates, validator checks, and install smoke tests.
