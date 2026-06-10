# b-ship reference

Edge-case guidance for `b-ship`.

## Mixed staged and unstaged changes

If staged and unstaged changes coexist, stop before committing. Ask the user which files to
include rather than staging everything or silently dropping unstaged changes. Only stage what is
explicitly confirmed as part of the intended payload.

## Multi-remote and diverged upstream

Before pushing, check `git status -sb` and `git log @{u}..HEAD` (or equivalent). Stop if:

- The upstream is ahead or diverged — do not force-push; report the conflict and ask how to resolve.
- No upstream is set — report the missing tracking branch and ask which remote and branch to use.
- Multiple remotes exist and the target is ambiguous — ask before assuming `origin`.

## Merge conflict at push time

If `git push` fails due to a remote conflict (non-fast-forward), do not run `git pull` or rebase
automatically. Report the rejection, show the upstream commit(s) causing the conflict, and ask
how the user wants to proceed (rebase, merge, or investigate divergence first).

## Failed gh auth

If `gh auth status` fails or is unavailable:

1. Print the push URL for the branch.
2. Print the manual `gh pr create` command with the resolved title, base, and body so the user
   can run it themselves.
3. Stop — do not attempt workarounds or alternative PR-creation methods.

## Draft PR

Pass `--draft` when the user requests it or when the diff review produced `READY WITH FOLLOW-UPS`
and the user has not explicitly said they want a full PR. A draft PR signals that follow-up work
is expected before merge.

## Empty or vague test plan

If the PR body test plan would be empty or consist only of "N/A" or "none", ask the user to
confirm before opening. Do not invent test steps. An explicit user acknowledgement that no test
plan is needed is sufficient to proceed.

## Commit hygiene

- Never amend or force-push published commits (commits already on the remote) without explicit
  user instruction naming the commit and confirming the rewrite.
- Never use `--no-verify` to bypass hooks unless the user explicitly requests it and the hook
  failure has been investigated.
- Never stage files outside the confirmed payload, including auto-generated, lockfile, or
  untracked files that appear as a side effect of prior steps.

## Post-PR scope

b-ship stops after printing the PR URL. Deploy triggers, release tags, version bumps, and
branch cleanup are out of scope unless explicitly added to the plan and approved.
