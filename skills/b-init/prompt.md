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

Read `{{skill_support_path}}/references/templates.md` before drafting or refreshing the file body.

## Steps

1. Confirm scope: repository root or a specific subtree, and whether the task is create, refresh, or reconcile.
2. Inspect only the repo evidence needed to avoid boilerplate: existing docs, manifests, validation scripts, top-level directories, and source-of-truth files.
3. Prefer `AGENTS.md` as the only authoritative instruction file. Keep `CLAUDE.md` short and route the reader to `AGENTS.md`.
4. When creating a new `AGENTS.md` or `CLAUDE.md`, wrap the generated body in `b-init` managed markers so later refreshes can update only the managed section.
5. If the target file contains `b-init` managed markers, update only the managed block. If it already has substantial unmarked content, preserve it and ask before replacing it wholesale.
6. Write concise sections grounded in repo evidence: what the repo is, how to work here, how to verify changes, codebase map, safety or do-not-assume rules, source-of-truth files, and maintainer guidance when the repo has generated assets, adapters, or contributor invariants.
7. For maintainer guidance, explain how to edit the repo without drifting generated outputs, adapters, or public docs. In `b-agentic`, cover canonical source layers, generated assets, validation commands, runtime neutrality, and the slimness rule against ceremony.
8. Avoid runtime-home paths, agent-vendor policy dumps, speculative architecture summaries, and extra root docs unless the user asked for them.
9. Verify that referenced paths and commands exist, then inspect the diff for noise or invented detail.

## Output format

Files changed, repo evidence used, verification, and any TODOs left intentionally unresolved.

## Rules

- Keep `AGENTS.md` primary and `CLAUDE.md` minimal.
- Prefer repo facts over generic policy text.
- Use explicit TODOs instead of guessing commands, owners, or workflows.
- Preserve user-owned content outside managed blocks.
- Keep the docs slim; do not turn initialization into a governance dump.
