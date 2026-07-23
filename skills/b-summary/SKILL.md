---
name: b-summary
description: >
  Analyze the staged changes of the current branch and write a concise
  Conventional Commits message, PR title, and structured PR description
  for one cohesive change without checking remotes or merge state.
argument-hint: "[change-context]"
---

<!-- Generated from skills/registry.yaml and skills/b-summary/prompt.md. Edit those sources, not this file. -->

# b-summary

$ARGUMENTS

Write one commit message, PR title, and concise PR description for one cohesive staged change.

## When to use

- The user wants commit and PR copy for staged changes.

## When NOT to use

- There are no staged changes.
- The user wants an explanation of the diff rather than commit/PR copy.
- The staged set mixes unrelated concerns that should be split.

## Tool guidance

- `bash` - inspect Git status and staged changes.

## Steps

1. Run `rtk git status --short` and inspect `rtk git diff --staged` using Bash.
2. Block if the staged diff is empty or mixes unrelated concerns.
3. Choose the narrowest accurate type: `feat`, `fix`, `refactor`, `perf`, `docs`, `test`, `chore`, or `style`.
4. Write an imperative commit subject of at most 50 characters with no trailing punctuation.
5. Write a PR title of at most 72 characters.
6. Describe only facts supported by the staged diff, user context, or verification evidence.
7. Keep the PR description compact for a small cohesive change. Expand only when problem, decision, implementation, and impact need separate treatment.

## Output format

```markdown
Commit message:
<type>: <subject>

PR title:
<title>

PR description:
<one concise paragraph or up to three bullets; expand only when needed>
```

When blocked, output exactly one of:

```text
BLOCKED: no changes to summarize
BLOCKED: split unrelated staged changes
```

## Rules

- Evidence-only claims. Use `Not established from available evidence.` instead of inventing root cause, decision, impact, or verification.
- Do not inspect remotes, merge bases, or open PR state.
- Do not run `git commit`, push, or create a PR.
