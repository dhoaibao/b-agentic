---
name: b-init
description: >
  Initialize or refresh repo-local agent instruction docs: canonical
  AGENTS.md plus a minimal CLAUDE.md shim that routes readers to
  AGENTS.md. Grounds the docs in repo evidence, preserves user-owned
  content, and keeps the output slim.
argument-hint: "[repo-root-or-subtree]"
---

<!-- Generated from skills/registry.yaml and skills/b-init/prompt.md. Edit those sources, not this file. -->

# b-init

$ARGUMENTS

Initialize or refresh repo-local agent instruction docs. `AGENTS.md` is canonical. `CLAUDE.md` is a thin redirect shim.

## When to use

- The user wants a project-level `/init` equivalent for agent guidance.
- `AGENTS.md` or `CLAUDE.md` is missing, stale, or inconsistent.
- A repo needs a concise maintainer guide grounded in its actual structure.

## When NOT to use

- The task is runtime-home installation or adapter config -> use repo docs or installer flow.
- The user wants a broader plan before writing docs -> use **b-plan**.
- The user wants code or product behavior changes -> use **b-implement**.

## Tools required

- `bash` - inspect repo files, commands, and diffs.
- `serena` - inspect structure when file ownership or code layout affects the guide.

## Steps

1. Confirm scope: repository root or a specific subtree, and whether the task is create, refresh, or reconcile.
2. Inspect only the repo evidence needed to avoid boilerplate: existing docs, manifests, validation scripts, top-level directories, and source-of-truth files. Use Serena to inspect file/module ownership when it affects the codebase-map section.
3. Prefer `AGENTS.md` as the only authoritative instruction file. Keep `CLAUDE.md` short and route the reader to `AGENTS.md` using the exact shim pattern:
   ```markdown
   # Claude Code Instructions

   Read `./AGENTS.md` first. It is the source of truth for this repository's agent instructions and maintainer guidance.
   ```
4. Wrap the generated content in managed markers so later refreshes can update only the managed section:
   ```markdown
   <!-- b-init-managed:start -->
   ...
   <!-- b-init-managed:end -->
   ```
5. If the target file contains these markers, update only the managed block. Preserve user-owned notes above or below it. If it contains substantial unmarked content, ask before replacing it wholesale.
6. Write concise `AGENTS.md` sections grounded in repo evidence:
   - Repository purpose: one short paragraph on what the repo ships or maintains.
   - Working rules: local conventions, edit boundaries, and approval expectations.
   - Verification commands: only list commands that exist in the repo.
   - Codebase map: top-level directories or packages that matter for navigation.
   - Safety rules: constraints on migrations, secrets, or generated-vs-source invariants.
   - Maintainer guide: edit guidelines (e.g. sync scripts) when the repo has generated files.
   - Source-of-truth files: registries, templates, or docs that own generated outputs.
7. Avoid runtime-home paths, agent-vendor policy dumps, speculative architecture summaries, and extra root docs.
8. Verify that referenced paths and commands exist (using Bash to run checks), then inspect the diff for noise or invented detail.

## Output format

Files changed, repo evidence used, verification, and any TODOs left intentionally unresolved.

## Rules

- Keep `AGENTS.md` primary and `CLAUDE.md` minimal.
- Prefer repo facts over generic policy text.
- Use explicit TODOs instead of guessing commands, owners, or workflows.
- Preserve user-owned content outside managed blocks.
- Keep the docs slim; do not turn initialization into a governance dump.
