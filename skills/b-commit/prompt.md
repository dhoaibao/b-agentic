# b-commit

$ARGUMENTS

Write one Conventional Commits message for a cohesive staged diff.

## When to use

- The user wants a commit message for staged changes.
- The user asks to summarize staged changes as a commit line.

## When NOT to use

- There are no staged changes.
- The user wants an explanation of the diff.
- Staged changes mix unrelated concerns that should be committed separately.

## Tools required

- `bash` - `git diff --staged`, `git status --short`.

## Steps

1. Run `git status --short` to confirm there are staged changes.
2. Run `git diff --staged` to read the staged diff.
3. Block if the staged set mixes unrelated concerns.
4. Choose the narrowest accurate type: `feat`, `fix`, `refactor`, `perf`, `docs`, `test`, `chore`, or `style`.
5. Write a specific imperative subject, at most 50 characters, with no trailing punctuation.
6. Output only one line.

## Output format

For a cohesive staged set, output a single line:

```text
<type>: <subject>
```

When blocked, output one of these exact forms:

```text
BLOCKED: no staged changes
BLOCKED: split unrelated staged changes
```

## Rules

- Use a Conventional Commits line only for cohesive staged changes.
- Use the exact blocked output when staged changes are absent or unrelated.
- Output one plain-text line with no explanation or alternatives.
- Do not run `git commit`.
