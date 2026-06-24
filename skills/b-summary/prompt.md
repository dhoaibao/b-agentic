# b-summary

$ARGUMENTS

Write one commit message, PR title, and concise PR description for one cohesive staged change.

## When to use

- The user wants commit and PR copy for staged changes.
- The user asks for a concise change summary before committing or opening a PR.

## When NOT to use

- There are no staged changes to summarize.
- The user wants an explanation of the diff.
- The change set mixes unrelated concerns that should be split.

## Tools required

- `bash` - inspect Git status and staged changes.

## Steps

1. Run `git status --short` and inspect `git diff --staged`.
2. Block if the staged diff is empty or mixes unrelated concerns.
3. Use the staged diff for the commit message, PR title, and PR description.
4. Choose the narrowest accurate commit type: `feat`, `fix`, `refactor`, `perf`, `docs`, `test`, `chore`, or `style`.
5. Write a specific imperative commit subject of at most 50 characters with no trailing punctuation.
6. Write a concise PR title of at most 72 characters.
7. Describe only facts supported by the staged diff, user context, or verification evidence.
8. Choose each PR section heading from the staged diff and your analysis. Use a single heading, not a slash-pair option.

## Output format

For a cohesive change, output exactly:

```markdown
Commit message:
<type>: <subject>

PR title:
<title>

PR description:
## <problem-or-capability heading>
<concise problem or capability>

## <cause-or-decision heading>
<confirmed root cause or key decision and rationale>

## <implementation heading>
<concise implementation summary>

## Impact Analysis
<behavior, compatibility, risk, configuration, migration, and verification impact>
```

When blocked, output one of these exact forms:

```text
BLOCKED: no changes to summarize
BLOCKED: split unrelated staged changes
```

## Rules

- Choose `Issue`, `Root Cause`, and `Fix` for defect repairs or regressions; choose `Feature`, `Decision`, and `Change` for new capabilities, docs, tooling, configuration, or intentional behavior changes. Mix these only when the staged diff clearly supports a mixed framing.
- Keep each PR section to one short paragraph or at most three bullets.
- Use `Not established from available evidence.` instead of inventing a root cause, decision, impact, or verification result.
- Do not include issue IDs unless supplied by the user or present in repository evidence.
- Always return the commit message, PR title, and complete PR description when a cohesive staged change set exists.
- Use the exact blocked output when required evidence is absent or unrelated.
- Do not inspect remotes, merge bases, or open PR state.
- Do not run `git commit`, push, or create a PR.
