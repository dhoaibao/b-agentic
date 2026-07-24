---
name: b-pr-summary
description: >
  Analyze a specified number of latest local commits, or commits ahead of
  the local cached origin branch ref when no count is given, and write
  evidence-backed PR title and description.
argument-hint: "[commit-count]"
---

<!-- Generated from skills/registry.yaml and skills/b-pr-summary/prompt.md. Edit those sources, not this file. -->

# b-pr-summary

$ARGUMENTS

Write general PR copy for a specified number of latest commits, or commits ahead of the local cached `origin/<current-branch>` ref when no count is provided.

## When to use

- The user wants a PR title and description for a specified number of recent commits or commits ahead of the local cached `origin/<current-branch>` ref.

## When NOT to use

- The user wants to create or split commits -> use **b-commit**.
- The user wants PR copy for staged changes -> use **b-commit** to receive the required commit-first blocker.
- The user wants a review of code or PR copy -> use **b-review**.

## Tool guidance

- `bash` - inspect local commits and local `origin` tracking refs without contacting the remote.

## Steps

1. If `$ARGUMENTS` is provided, require it to be one positive commit count, such as `b-pr-summary 3`, then inspect exactly that many commits from `HEAD`. Block if the branch has fewer commits or the count is invalid.
2. If no count is provided, resolve the current branch and inspect the local `origin/<current-branch>` tracking ref without fetching. Block if that ref does not exist; otherwise select `origin/<current-branch>..HEAD`. Block if the range is empty.
3. Using Bash, inspect the selected commits, their messages, changed files, and diffs.
4. Write a PR title of at most 72 characters that represents the combined change, not a single commit message.
5. Summarize the overall purpose and key changes across the selected commits. Group related details; do not repeat each commit log mechanically.
6. Include only verification evidence established by the selected commits or supplied user context. Use `Not established from available evidence.` when verification is unknown.
7. Include risks or follow-up only when supported by evidence.

## Output format

```markdown
PR title:
<title>

PR description:
<one concise overview>

Key changes:
- <combined, evidence-backed change>

Verification:
- <evidence or Not established from available evidence.>

Risks / follow-up:
- <evidence-backed item or None>
```

When blocked, output exactly one of:

```text
BLOCKED: invalid commit count
BLOCKED: not enough commits to summarize
BLOCKED: origin branch not found
BLOCKED: no commits ahead of cached origin to summarize
```

## Rules

- Evidence-only claims. Do not invent root cause, decision, impact, or verification.
- Do not contact remotes, fetch, push, inspect merge bases, or open PR state.
- Do not stage, commit, push, or create a PR.
