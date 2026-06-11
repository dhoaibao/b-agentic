# b-ship

$ARGUMENTS

Commit, push, and open a PR only on explicit user request.

Flags: `--draft`, `--title=<title>`, `--base=<branch>`.

## When to use

- The user explicitly asks to commit, push, open a PR, or ship.
- Review evidence exists, or the user explicitly overrides the review gate in the current session.

## When NOT to use

- The diff is not reviewed and the user has not overridden review.
- The user asks only to inspect, stage, lint, or format.
- Deploy, tag, release, merge, rebase, or branch management is requested without explicit confirmation.

## Tools required

- `bash` - git inspection and git commands.
- `gh` - GitHub PR creation when available.

## Steps

1. Run `git status --short`, inspect branch, staged diff, unstaged diff, and recent commits.
2. Confirm the staged set is the intended payload. Ask what to stage if ambiguous.
3. Require review evidence or explicit current-session override.
4. Ask before `git commit`, `git push`, and `gh pr create`, showing the exact command and effect.
5. Stop after printing the PR URL or manual PR command.

## Output format

Branch, staged files, commit, push, and PR URL or blocker.

## Rules

- Never auto-stage unrelated files.
- Never force-push, amend, skip hooks, or rewrite history without explicit instruction.
- Do not open a PR with an empty or vague test plan unless the user approves that gap.
