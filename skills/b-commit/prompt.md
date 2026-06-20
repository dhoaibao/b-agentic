# b-commit

$ARGUMENTS

Analyze the staged diff and write one Git commit message following Conventional Commits only when the staged set is cohesive.

## When to use

- The user wants a commit message for staged changes.
- The user asks to summarize staged changes into a commit line.

## When NOT to use

- There are no staged changes.
- The user wants an explanation of the diff.
- Staged changes mix unrelated concerns that should be committed separately.

## Tools required

- `bash` - `git diff --staged`, `git status --short`.

## Steps

1. Run `git status --short` to confirm there are staged changes.
2. Run `git diff --staged` to read the staged diff.
3. Check that the staged set is cohesive enough for one commit.
4. Choose the Conventional Commits type that best matches the staged change.
5. Write a specific, imperative subject that describes what changed.
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

- Output only one line.
- Use a Conventional Commits line only for cohesive staged changes.
- If the staged set mixes unrelated concerns, output `BLOCKED: split unrelated staged changes`.
- If there are no staged changes, output `BLOCKED: no staged changes`.
- No explanation, no markdown, no alternatives.
- Do not run `git commit`.
