# b-change-summary

$ARGUMENTS

Write one commit message, PR title, and concise PR description for one cohesive change.

## When to use

- The user wants commit and PR copy for staged or committed branch changes.
- The user asks for a concise change summary before committing or opening a PR.

## When NOT to use

- There are no staged or committed branch changes to summarize.
- The user wants an explanation of the diff.
- The change set mixes unrelated concerns that should be split.

## Tools required

- `bash` - inspect Git status, staged changes, branch history, and the base branch.

## Steps

1. Run `git status --short` and inspect `git diff --staged`.
2. Resolve the base branch from user context or the remote default branch. Block instead of guessing when neither identifies it.
3. Find the merge base and compare it with the Git index so the PR summary covers committed branch changes plus staged changes, but not unstaged work.
4. Block if that prospective PR diff is empty or mixes unrelated concerns.
5. If staged changes exist, use the staged diff for the commit message and block if it mixes unrelated concerns. Otherwise use the prospective PR diff as a squash-commit summary.
6. Choose the narrowest accurate commit type: `feat`, `fix`, `refactor`, `perf`, `docs`, `test`, `chore`, or `style`.
7. Write a specific imperative commit subject of at most 50 characters with no trailing punctuation.
8. Write a concise PR title of at most 72 characters.
9. Describe only facts supported by the diff, commit history, user context, or verification evidence.

## Output format

For a cohesive change, output exactly:

```markdown
Commit message:
<type>: <subject>

PR title:
<title>

PR description:
## Issue/Feature
<concise problem or capability>

## Root Cause/Decision
<confirmed root cause or key decision and rationale>

## Fix/Change
<concise implementation summary>

## Impact Analysis
<behavior, compatibility, risk, configuration, migration, and verification impact>
```

When blocked, output one of these exact forms:

```text
BLOCKED: no changes to summarize
BLOCKED: split unrelated staged changes
BLOCKED: base branch not found
BLOCKED: split unrelated PR changes
```

## Rules

- Keep each PR section to one short paragraph or at most three bullets.
- Use `Not established from available evidence.` instead of inventing a root cause, decision, impact, or verification result.
- Omit unaffected impact categories; do not add boilerplate checklists.
- Do not include issue IDs unless supplied by the user or present in repository evidence.
- Always return the commit message, PR title, and complete PR description when a cohesive change set exists.
- Use the exact blocked output when required evidence is absent or unrelated.
- Do not run `git commit`, push, or create a PR.
