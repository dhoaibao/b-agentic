---
name: b-commit
description: >
  Analyze the staged diff and write one Git commit message following
  Conventional Commits. Output ONLY the commit message — a single line. No
  explanation, no markdown, no alternatives.
argument-hint: "[staged-diff-context]"
---

<!-- Generated from skills/registry.yaml and skills/b-commit/prompt.md. Edit those sources, not this file. -->

# b-commit

$ARGUMENTS

Analyze the staged diff and write one Git commit message following Conventional Commits.

## When to use

- The user wants a commit message for staged changes.
- The user asks to summarize staged changes into a commit line.

## When NOT to use

- There are no staged changes.
- The user wants an explanation of the diff.

## Tools required

- `bash` - `git diff --staged`, `git status --short`.

## Steps

1. Run `git status --short` to confirm there are staged changes.
2. Run `git diff --staged` to read the staged diff.
3. Choose the Conventional Commits type that best matches the staged change.
4. Write a specific, imperative subject that describes what changed.
5. Output only the commit message.

## Output format

A single line:

```text
<type>: <subject>
```

Types:

- `feat`: new feature or capability
- `fix`: bug fix
- `refactor`: code restructure without behavior change
- `perf`: performance improvement
- `docs`: documentation only
- `test`: tests only
- `chore`: tooling, deps, config, build
- `style`: formatting only

Subject rules:

- Imperative mood (`add`, `fix`, `remove` — not `added`, `fixes`, `removed`)
- Max 50 characters
- No trailing punctuation
- Specific: describe what changed, not that something changed

Examples:

- ✗ `update config`
- ✓ `add retry limit to fetch hook`

## Rules

- Output ONLY the commit message — a single line.
- No explanation, no markdown, no alternatives.
- Do not run `git commit`.
- If the staged set mixes unrelated concerns, pick the dominant change.
