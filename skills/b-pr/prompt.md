# b-pr

Push the current branch to `origin` and create a draft GitHub PR from its commits with `git` and `gh`, after an explicit user request.

## When to use

- The user explicitly asks to create or open a PR, or to push the branch and open a PR, for the current branch.

## When NOT to use

- The user wants to create or split commits -> use **b-commit**.
- The user wants a PR for staged changes -> use **b-commit** to receive the required commit-first blocker.
- The user wants changed-code review -> use **b-review**.
- The user wants PR text only, without a push or PR -> this skill does not apply; answer directly.

## Tool guidance

- `bash` - `rtk git` for local reads and the push, `gh` for GitHub reads, PR creation, and switching between already logged-in accounts. The harness asks before `git push`, `gh pr create`, and `gh auth switch`; force, delete, mirror, all-branch, and default-branch pushes, `gh pr merge`, `gh repo delete`, `gh auth login`/`logout`/`token`/`refresh`, and other destructive or credential-changing `gh` commands are denied. The HTTPS `git -c ... push` form is denied only for force and default-branch pushes; its other forbidden pushes are caught by the prompt rules and the ask prompt alone.
- `AskUserQuestion` - choose the base branch when it is ambiguous.

## Steps

### Preflight

Preflight is read-only except the account switch in step 5. Stop at the first failed check with exactly its `BLOCKED:` line.

1. Run `rtk git status --short`. Block on staged or unstaged tracked changes with `BLOCKED: uncommitted tracked changes; commit them with b-commit first`. Ignore untracked files.
2. Resolve the branch with `git symbolic-ref --quiet --short HEAD`. A detached HEAD blocks with `BLOCKED: detached HEAD`.
3. Check `git remote get-url --all origin` and `git remote get-url --push --all origin`. A missing remote blocks with `BLOCKED: origin remote not found`. A push goes to every push URL (or every URL when none is set), so block with `BLOCKED: origin must have exactly one fetch URL and one push URL` when either list has more than one entry. Derive `<repo>` as `OWNER/REPO` (prefixed with `HOST/` unless the host is github.com) from the push URL in its HTTPS, `ssh://`, or `git@host:owner/repo` form with a trailing `.git` removed. For an SSH URL, take `HOST` from the `hostname` line of `ssh -G <url-host>` so an SSH config alias such as `github-personal.com` resolves to its real host, and keep the URL form as `<transport>` (`https` or `ssh`). Block with `BLOCKED: origin fetch and push URLs name different repositories` when the fetch URL names another repository, and with `BLOCKED: origin is not a GitHub repository` when no repository can be derived. Bind every later `gh` call to `<repo>` explicitly (`-R <repo>`, or the repository argument of `gh repo view`) so neither `GH_REPO` nor Git's implicit choice can redirect it.
4. Run `gh auth status --hostname <host>` (`github.com` unless `<repo>` has a `HOST/` prefix). No logged-in account blocks with `BLOCKED: gh not authenticated`. Never run `gh auth login`; logging in belongs to the user. Record each `Logged in to <host> account <login>` and which one reads `Active account: true` as `<orig>`.
5. Select the account for `<repo>`. When `GH_TOKEN`, `GITHUB_TOKEN`, `GH_ENTERPRISE_TOKEN`, or `GITHUB_ENTERPRISE_TOKEN` is set (test only that it is non-empty, never print it), it overrides every stored account: do not switch, check `viewerPermission` for that token alone, and block with `BLOCKED: gh environment token cannot push to <repo>` when it is not `ADMIN`, `MAINTAIN`, or `WRITE`. Otherwise try the account whose login equals the repository owner (case-insensitive) first, then `<orig>`, then the rest in listed order. For each candidate other than the current active account, run `gh auth switch --hostname <host> --user <login>` first, then `gh repo view <repo> --json viewerPermission -q .viewerPermission`. Keep the first candidate that returns `ADMIN`, `MAINTAIN`, or `WRITE`; a failed lookup or lower permission moves to the next. When none qualifies, switch back to `<orig>` and block with `BLOCKED: no gh account on <host> can push to <repo>`. The switch selects the identity for `gh` and, over HTTPS, for the push in Ship step 1; it never changes an SSH key. Switching only moves between accounts already logged in, never reads or prints a token, and every later block, failure, or finish ends by switching back to `<orig>` when the selected account differs.
6. Resolve the default branch with `gh repo view <repo> --json defaultBranchRef -q .defaultBranchRef.name`. When that fails, block with `BLOCKED: default branch not resolvable`. When the current branch is the default, block with `BLOCKED: current branch is the default branch`.
7. Compare the cached `origin/<branch>` ref without fetching: `git rev-list --left-right --count origin/<branch>...HEAD`. Behind or diverged blocks with `BLOCKED: branch is behind or diverged from origin/<branch> (<behind> behind, <ahead> ahead)`; never force, pull, or rebase. A missing ref means a first push; equal counts mean no push is needed.
8. Resolve the upstream with `git rev-parse --abbrev-ref @{upstream}`. No upstream means push with `-u`; an upstream equal to `origin/<branch>` means push without `-u`; anything else blocks with `BLOCKED: upstream points to <upstream>`.
9. Look for an existing PR with `gh pr list -R <repo> --head <branch> --state open --json url,baseRefName --limit 1`. When one exists, push if the branch is ahead, report its URL, and skip the base question and creation.

### Choose the base

1. An explicit base from the request wins when `origin/<base>` exists. Otherwise find the parent: first `git config --get branch.<branch>.b-agentic-parent`; then the oldest entry of `git reflog show --format=%gs refs/heads/<branch>`, only when it reads `branch: Created from <ref>` and `<ref>` is not `HEAD`, with an `origin/` or `refs/heads/` prefix removed. The parent is valid only when it is not the current branch and the cached `origin/<parent>` ref exists.
   - A valid parent that differs from the default: ask once with `AskUserQuestion` whether to use the default branch or the parent as the base.
   - A parent equal to the default: use the default without asking.
   - No valid parent: ask with the default branch offered and a typed base allowed through Other.
   - Never guess a base from the nearest-looking branch.
   Require a non-empty `origin/<base>..HEAD`; otherwise block with `BLOCKED: no commits ahead of origin/<base>`.

### Write the PR copy

Write it from evidence and do not show it in the chat.

1. Enumerate `origin/<base>..HEAD` with metadata-only `rtk git log` and `rtk git diff --name-only`. Classify protected paths before any content read, inspect diffs only for non-protected paths with `rtk git show <commit> -- <paths>` or a targeted range diff, and state that protected paths were excluded without exposing their contents.
2. Write a title of at most 72 characters for the combined change, not a single commit message. Write the description as one overview, grouped key changes, verification only when the commits or user context establish it (otherwise `Not established from available evidence.`), and risks or follow-up only when evidence supports them.

### Ship

1. Push with a fully qualified refspec so no `remote.origin.push` mapping can change the destination: `rtk git push [-u] origin refs/heads/<branch>:refs/heads/<branch>`. For an `https` `<transport>`, run it with the command-scoped helper `rtk git -c credential.helper= -c 'credential.helper=!gh auth git-credential' push ...` so the push authenticates as the selected account without changing git configuration; an `ssh` push keeps its configured SSH identity, so a rejection is reported as is. Never run a bare `git push` and never push the default branch. Skip the push when preflight step 7 found equal counts.
2. Create the PR as a draft. Pass the title as a single-quoted argument (replace each `'` with `'\''` and drop newlines, so backticks and `$()` stay literal) and the body on stdin through a heredoc whose delimiter does not occur in the body: `gh pr create -R <repo> --draft --base <base> --head <branch> --title '<title>' --body-file - <<'PR_BODY_EOF'` followed by the description and `PR_BODY_EOF`.
3. Switch back to `<orig>` when step 5 changed the active account, whether the push and PR succeeded or failed. On any failure, report the reason from git or gh and stop. Never retry with force, amend, reset, pull, or rebase, and never delete the remote branch. When the push succeeded but PR creation failed, report `Pushed <branch>; PR not created: <reason>`. When gh reports an existing PR, report its URL from `gh pr view -R <repo> <branch> --json url -q .url`.

## Output format

Exactly these lines, with no summary of the PR copy:

```text
Pushed: <branch> -> origin/<branch>
Draft PR: <url>
```

Use `Already up to date on origin: <branch>` when no push was needed, and `Existing PR: <url>` when a PR already existed. When blocked, output exactly one `BLOCKED:` line from the steps above.

## Rules

- Require an explicit user request; one invocation creates at most one PR.
- Evidence-only claims. Do not invent root cause, decision, impact, or verification.
- Push only the current non-default branch to `origin` with an explicit destination.
- Shell-quote every branch, ref, repository, and title value placed in a command so none runs as shell code: single-quote a value (embedding `'` as `'\''`) when it has a character outside `[A-Za-z0-9._/-]`, always single-quote the title, and leave plain values unquoted so the push deny rules can match them.
- Create the PR as a draft; do not mark it ready, edit it, or merge it.
- Do not stage, commit, fetch, pull, rebase, or change history.
- Never run `gh auth login`; use `gh auth switch` only between accounts already logged in, to match `<repo>`, and restore `<orig>` afterward. Never print a token or run `gh auth status --show-token`. Never expose protected file contents.
