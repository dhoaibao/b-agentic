# b-commit

Create cohesive commits from an explicit user request, or draft one message for an existing staged change, without pushing.

## When to use

- The user wants working-tree changes split, staged, and committed on the current branch.
- The user wants a commit message only for one cohesive staged change.
- The user wants PR copy for staged changes and needs a clear next step.

## When NOT to use

- The user wants PR copy for already-created commits -> use **b-pr-summary**. (PR copy for staged changes stays here: step 1 returns the commit-first blocker.)
- The changes cannot be grouped confidently -> use **b-plan**.
- The user wants a review before committing -> use **b-review**.

## Tool guidance

- Native `read`/`edit` for applicable repository commit rules and required changelog preparation; `bash` for repository-prescribed validation, `rtk git status --short`, metadata-only Git path lists, targeted safe-path diffs, exact staging, and commit creation.

## Review and commit gate

The main session owns `b-commit`. An explicit user request to commit authorizes the smallest confident cohesive plan. Do not ask for a second approval prompt. Complete repository-required commit preparation and checks, inspect the full tracked and relevant untracked/derived candidate, then capture its exact snapshot and commit plan before staging. Apply the kernel's risk-triggered review rule to the prepared candidate and plan; a single cohesive low-risk group with no pre-existing staged set may proceed after a self-audit of exact paths, index, message, and passing required checks. Multiple groups, a pre-existing staged set, uncertain path assignment, or any other review trigger requires independent review. Supply b-reviewer with each proposed group's exact paths, message, and any pre-existing staged set when review is required.

- When review is required, require a valid independent **b-reviewer** disposition explicitly covering the exact candidate and commit plan. A candidate-only verdict does not approve staging. If either is absent or changed—including relevant untracked content or required changelog preparation—freeze the candidate, request or reopen review, then pause without staging or editing. For a low-risk exception, recheck the classification and self-audit the unchanged prepared snapshot and plan before staging; a change requires fresh checks and reclassification. Failed checks, unexpected paths, or unresolved findings block committing. Never regroup silently or push.

## Steps

1. If the user asks for PR copy for staged changes, return `BLOCKED: commit staged changes before generating PR copy` and stop. Do not inspect commit history or stage or commit changes.
2. If the user asks only for a commit message, list staged paths with `rtk git diff --cached --name-only`, then inspect only the targeted staged diff for non-protected paths. Block if it is empty, protected, or mixes unrelated concerns; otherwise apply step 7, output the message, and stop without staging or committing.
3. Using Bash, run `rtk git status --short` and metadata-only path lists for staged and unstaged changes. Classify protected paths before reading any content; inspect untracked files only when their paths are not likely-secret files.
4. Read diffs only for explicit non-protected paths, using `rtk git diff -- <paths>` or `rtk git diff --cached -- <paths>`. Record the initial index and working-tree snapshot. Do not read, stage, or commit likely-secret files without explicit permission.
5. Select the smallest set of cohesive commit groups. Treat a pre-existing staged set as user-curated: preserve it as one group and do not reset or reorganize it.
6. Block if a group mixes unrelated concerns, a protected file needs permission, or a file cannot be assigned confidently. Before freezing the candidate, read applicable repository commit rules and perform required preparation only for this user-authorized commit. Update `CHANGELOG.md` when required, following the repository's date/category convention; do not impose a changelog on repositories without that rule. Run the prescribed changelog validator when present and all required checks. Include prepared files in the commit plan without silently adding them to or rewriting a user-curated staged group; if grouping is ambiguous, stop. Message-only and staged PR-copy requests never reach this preparation step.
7. For each group, choose the narrowest accurate type: `feat`, `fix`, `refactor`, `perf`, `docs`, `test`, `chore`, or `style`; write an imperative subject of at most 50 characters with no trailing punctuation.
8. Record the groups, exact file paths, and commit messages in the execution response, then continue without a second approval prompt; the explicit user commit request is sufficient authorization. If the request did not explicitly authorize committing, stop.
9. Apply the risk-triggered review and commit gate above to the complete candidate and plan. Before staging, verify the snapshot and commit plan are unchanged and required checks passed. For a low-risk exception, report that independent review was skipped; do not claim an independent review verdict. Stage only the selected paths for each unstaged group; do not use broad staging commands that can capture unrelated files.
10. Reinspect each staged group immediately before committing with a targeted non-protected-path diff. Create its commit on the current branch, then continue to the next approved group. Stop on the first Git error; do not amend, reset, push, or retry by changing history.
11. Report commit hashes, messages, remaining changes, and any blockers. Recommend `b-pr-summary <commit-count>` for PR copy.

## Output format

Execution plan:

```markdown
Commit plan:
1. <type>: <subject>
   Files: <paths>

The explicit user commit request authorizes execution; no second approval prompt is required.
```

For a message-only request:

```markdown
Commit message:
<type>: <subject>
```

After completion:

```markdown
Created commits:
- <short-hash> <type>: <subject>

Remaining changes:
- <paths or None>
```

When blocked, state the specific uncommitted concern without exposing protected file contents. For staged PR-copy requests, output exactly:

```text
BLOCKED: commit staged changes before generating PR copy
```

## Rules

- Preserve unrelated worktree changes and the user-curated index.
- Evidence-only messages; do not invent behavior, verification, or impact.
- Require an explicit user commit request, but do not ask for a second approval after it; do not push or create a PR.
- Commit only for the unchanged verified snapshot and plan. Any candidate or plan change requires fresh checks and risk reclassification; reopen **b-reviewer** review if review was or is required.
- Never use `git add -A`, `git add .`, `git commit --amend`, reset, or history-rewriting commands.
