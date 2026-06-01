# Before-Edit Card

Use this before editing files, writing artifacts, starting risky verification, or mutating a shared surface.

- Confirm the active skill and source of truth.
- Check `git status --short` and preserve unrelated user changes.
- For saved plans, validate approval, executable status, blocked dependencies, and staleness.
- Ask before dependency writes, dev servers, migrations, commits, destructive commands, shared-environment mutation, or external writes.
- Protect secrets, private data, and internal documents before any external tool use.
- Use the smallest coherent change and name planned verification before editing.

Modes:
- `lite` still checks source of truth and worktree state.
- `standard` adds the usual approval/worktree/privacy checks.
- `strict` makes approval, staleness, worktree, and verification gates explicit at the point of use.

The authoritative rules live in `../contract/02-source-of-truth.md`, `../contract/06-safety.md`, and `../contract/11-session.md`.
