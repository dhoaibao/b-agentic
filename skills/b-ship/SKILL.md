---
name: b-ship
description: >
  Commit, push, and open a pull request only on explicit ship intent after
  a reviewed diff is ready. A prior skill may close with Next: b-ship, but
  that is a recommendation, not an implicit shipping handoff. Safety-gates
  each git action (commit, push, PR creation); never force-pushes. Stops
  after the PR URL is printed; post-PR automation is out of scope.
argument-hint: "[--draft] [--title=<title>] [--base=<branch>]"
---

<!-- Generated from skills/registry.yaml and skills/b-ship/prompt.md. Edit those sources, not this file. -->

# b-ship

$ARGUMENTS

Commit the reviewed diff, push, and open a PR only on explicit ship intent. Confirm each git mutation unless already approved in the current session.

Flags: `--draft`, `--title=<title>`, `--base=<branch>` (default: main).

## When to use

- The user explicitly asks to commit, push, open a PR, or ship after `b-review` reports `READY FOR PR` or `READY WITH FOLLOW-UPS`.
- A prior skill may close with `Next: b-ship`, but that is a recommendation, not an implicit shipping handoff.

## When NOT to use

- The diff is not reviewed -> use **b-review** first.
- The user asks only to stage files or inspect the diff.
- Post-PR automation such as deploy, tag, or release is requested.
- Merge, rebase, or branch management is requested without explicit confirmation.

## Tools required

- `bash` - git actions; gh CLI is required for GitHub auth checks, push-adjacent PR status, and PR creation.

## Steps

### Step 1 - Confirm diff, review, and branch

Run `git status --short`, current branch, staged diff, unstaged diff, and recent commits. Report branch, staged files, unstaged/untracked files, and commit context before mutation.

Confirm the staged set is the intended payload. If staged/unstaged changes are mixed or nothing is staged, stop and ask which files to stage.

Require review evidence: a `b-review` status block with `state: complete`, `blockers: none`, and `verdict: READY FOR PR`; or an explicit current-session user override. Treat `READY WITH FOLLOW-UPS` as ship-ready only when the user explicitly accepts the named follow-ups in the current session. In a fresh session without context continuity, ask the user to re-run **b-review** rather than waiving the gate. If no review evidence exists, ask:

```text
No prior review evidence found. b-ship expects review before commit.
[approval] Proceed without review
Effect: commits and opens a PR without a b-review verdict.
Proceed? (y/n)
```

Read `../../b-agentic/references/contract/safety-tools.md` before commit or push.

### Step 2 - Commit

Inspect staged diff again. Ask for a commit message unless `--title` or user prose already provides one. Confirm:

```text
[approval] git commit -m "<message>"
Effect: creates a new commit on <branch> from the current staged diff with <N> changed files.
Proceed? (y/n)
```

Never amend or use `--no-verify` unless explicitly requested. Never stage extra files unless the user names them.

### Step 3 - Push

Check upstream, `git status -sb`, and commits to push. Stop if upstream is ahead, diverged, or ambiguous. Confirm:

```text
[approval] git push origin <branch>
Effect: pushes <N> new commits to remote <branch>.
Proceed? (y/n)
```

Never force-push unless explicitly requested.

### Step 4 - Open PR

Check `gh auth status`. If unavailable, print the push URL and manual PR command, then stop.

Resolve base branch, inspect PR diff/commits, draft title/body/test plan, and confirm:

```text
[approval] gh pr create --title "<title>" --base <base>
Effect: opens a new PR on <repo>. Output: PR URL.
Proceed? (y/n)
```

Pass `--draft` if requested. Stop after printing the PR URL.

## Output format

```text
Branch -> Staged files -> Commit -> Push -> PR URL
```

## Rules

- Ask before every destructive git action unless explicitly pre-approved.
- Inspect staged diff, unstaged diff, recent commits, upstream state, and base diff before the corresponding mutation.
- Do not auto-stage unrelated files or silently drop unstaged changes from expected scope.
- Never force-push, amend published commits, or skip hooks without explicit instruction.
- Do not open a PR with an empty or vague test plan unless the user approves that gap.
