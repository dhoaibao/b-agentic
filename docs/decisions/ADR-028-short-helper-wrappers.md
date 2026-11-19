# ADR-028: Short helper wrappers instead of long runtime commands

- Status: Accepted
- Date: 2026-11-19
- Supersedes: none; refines [ADR-018](ADR-018-bun-only-runtime.md) (its rule that every documented command is the long `bun --no-env-file --config=/dev/null <script>` form)

## Context

Skills, the kernel, and the docs told the model to type commands such as
`bun --no-env-file --config=/dev/null ~/.claude/b-agentic/bin/b-state.mjs check` and
`python3 -I -B ~/.claude/b-agentic/bin/b_run.py write spec`, dozens of times per `b-flow` run. The model kept
shortening them into a shell variable (`B="bun …"; $B check`). The Bash tool runs zsh, which does not split an
unquoted variable into words, so each such call failed with exit 127. A scan of the eight most recent session
transcripts found seven of these failures in five sessions, plus two unmatched globs and one `=====`
separator, all bash-isms that zsh rejects. A note in a skill was rejected: it asks the model to remember, while
the long command is the cause.

The long form exists for a reason ([ADR-018](ADR-018-bun-only-runtime.md)): without `--no-env-file
--config=/dev/null`, `bun` run inside a repository loads that repository's `bunfig.toml` preload and `.env`, and
the installer substitutes the absolute Bun path because a hook's shell may not have `~/.bun/bin` on `PATH`. A
shebang cannot carry the flags (Linux passes one argument; `env -S` finds Bun through `PATH`).

## Decision

- Five one-line `sh` wrappers are installed next to the helpers in `~/.claude/b-agentic/bin/`: `b-state`,
  `b-run` (`python3 -I -B` on `b_run.py`), `b-snapshot` (`b-candidate-snapshot.mjs`), `b-codex-review`, and
  `b-codex-guard` (`hooks/b-codex-guard.mjs`, used for `--check`). Each is `exec <runtime> <flags>
"${0%/*}/<target>" "$@"`, so arguments, stdin, and the exit code pass through.
- Skills, the kernel, the registry, and the docs name `~/.claude/b-agentic/bin/<name>` followed by its
  arguments as one token, never through a variable. `b-flow` maps the shorthand `b-state.mjs <command>` and
  `b_run.py <command>` in its text and in the `next` lines to the wrappers; the hint names in `next` are unchanged.
- The ADR-018 hardening moves into the wrapper: each bun wrapper carries both flags, and the installer replaces
  the bare `bun` with the absolute path it found (symlinks kept), as for the hooks. The installer refuses to
  install a wrapper without that line, writes the wrappers owner-executable (0700), rewrites an owned wrapper
  that lost its exec bit, and records them in the manifest; uninstall removes them and still needs no Bun.
- Hook and status line commands in the settings file keep the long form; the model does not type them.
- The wrappers are source files in `claude/bin/`, not generated assets. `tooling/validate/shared.py` pins each
  wrapper's exact line and exec bit, and the install probe runs them with no Bun on `PATH` from a repository with a
  `bunfig.toml` preload and a `.env`.
- The worker profile and the implement packet forbid the wrappers like the helpers they wrap.

## Consequences

- One command string per helper, with no flags to forget or mistype, and none of the zsh failures above.
  The hardening is enforced in one place, so a caller cannot drop it.
- The kernel shrinks (11,998 to 11,947 bytes), and the installer ships five more owned files.
- A wrapper whose bun path is stale (Bun removed after install) fails with exit 127, as a hook would, and
  a re-install repairs it.
- Rejected: a zsh note in the skills, a shebang with `env -S`, a `PATH` directory, a shell variable or alias,
  resolving Bun at run time inside the wrapper (it would replace the install-time absolute path of ADR-018), and
  rendering the wrappers in `registry_sync.py` (they are not generated assets).

Evidence: [`claude/bin/b-state`](../../claude/bin/b-state),
[`tooling/install/claude_install.py`](../../tooling/install/claude_install.py),
[`tooling/validate/shared.py`](../../tooling/validate/shared.py), and
[`tests/install/claude-install-probe.sh`](../../tests/install/claude-install-probe.sh).
