# b-ship

$ARGUMENTS

Commit the reviewed diff, push, and open a pull request. Each destructive git action requires confirmation unless it was already approved in the current session.

Flags: `--draft` (open as draft PR), `--title=<title>` (skip interactive prompt), `--base=<branch>` (target branch, default: main).

## When to use

- The user asks to commit, push, open a PR, or ship after a review verdict of `READY FOR PR` or `READY WITH FOLLOW-UPS`.
- `b-orchestrate` closes a workflow with `Next: b-ship`.

## When NOT to use

- The diff is not reviewed -> use **b-review** first.
- The user asks only to stage files or inspect the diff -> use `bash` directly.
- The task needs post-PR automation (deploy, tag, release) -> out of scope; address separately.
- Merge, rebase, or branch management -> handle with direct `git` commands after user confirms.

## Tools required

- `bash` - git and gh CLI for all actions.

## Steps

### Step 1 - Confirm the diff, review status, and branch

Run `git status --short`, `git branch --show-current`, `git diff --staged`, `git diff`, and `git log --oneline -10`. Report branch, staged files, unstaged/untracked files, and the recent commit context before any mutating action.

Confirm that the staged set is the intended commit payload. If nothing is staged, or if the staged and unstaged changes are mixed in a way that risks committing unrelated work, stop and ask the user to confirm the exact files to stage. Do not auto-stage unrelated files.

Check for evidence of prior review: a `b-review` status block with `verdict: READY FOR PR` or `verdict: READY WITH FOLLOW-UPS`, or an explicit current-session user override. A saved plan or implementation note is context only; it does not satisfy shipping readiness. If no review evidence exists, stop and ask the user to confirm:

```text
No prior review evidence found. b-ship expects review before commit.
[approval] Proceed without review
Effect: commits and opens a PR without a b-review verdict.
Proceed? (y/n)
```

Read `{{runtime_reference_root}}/contract/06-safety.md` before any commit or push action.

### Step 2 - Commit

Inspect the staged diff one more time before committing so the final commit matches the reviewed payload. Ask for a commit message unless `--title` was provided or the user already gave one. Confirm:

```text
[approval] git commit -m "<message>"
Effect: creates a new commit on <branch> from the current staged diff with <N> changed files.
Proceed? (y/n)
```

Never amend an existing commit unless the user explicitly asks. Never use `--no-verify` unless the user explicitly asks. Never stage extra files as part of commit preparation unless the user explicitly names them.

### Step 3 - Push

Check whether the branch has an upstream with `git rev-parse --abbrev-ref @{u}` and inspect remote freshness with `git status -sb`. Review the commits that would be pushed. If the upstream is ahead, diverged, or ambiguous, stop and ask the user to resolve it before pushing.

Confirm:

```text
[approval] git push origin <branch>
Effect: pushes <N> new commits to remote <branch>.
Proceed? (y/n)
```

Never push with `--force` or `--force-with-lease` unless the user explicitly asks.

### Step 4 - Open PR

Check that `gh` is available (`gh auth status`). If not, print the push URL and manual PR creation command, then stop.

Resolve the base branch from `--base` or the default `main`, then inspect the diff and commits that will appear in the PR. If the base ref is unavailable locally or the included commit set is unclear, stop and ask before guessing.

Draft the PR title from the commit message or `--title`. Draft the body from the diff context with a short summary and a test plan that names commands run or says `Not run` with a reason. Confirm before creating:

```text
[approval] gh pr create --title "<title>" --base <base>
Effect: opens a new PR on <repo>. Output: PR URL.
Proceed? (y/n)
```

Pass `--draft` if requested. After creation, print the PR URL.

## Output format

```text
Branch -> Staged files -> Commit -> Push -> PR URL
```

## Rules

- Ask before every destructive git action unless explicitly pre-approved.
- Inspect staged diff, unstaged diff, recent commits, upstream state, and base-branch diff before the corresponding mutating action.
- Do not auto-stage unrelated files or silently drop unstaged changes from the user's expected scope.
- Never force-push, amend published commits, or skip hooks without explicit user instruction.
- Do not open a PR with an empty or vague test plan unless the user explicitly approves that gap.
- Stop after printing the PR URL. Do not continue to merge, deploy, or tag.
- If any step fails, surface the error and stop; do not silently retry.
- Read `{{runtime_reference_root}}/contract/06-safety.md` at Step 1 before any git mutation.
- Read `{{runtime_reference_root}}/contract/09-output.md` before closing a non-trivial run with a status block.
