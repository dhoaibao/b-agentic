# ADR-018: Bun is the only runtime for Claude Code, with hardened flags and no Node fallback

- Status: Accepted
- Date: 2026-11-15
- Supersedes: ADR-017 (its Node fallback, `--js-runtime`, `B_AGENTIC_JS_RUNTIME`, and the `auto` and `node` modes)

## Context

[ADR-017](ADR-017-bun-hook-runtime.md) let the installer point the managed hooks and
status line at Bun when one was found and kept Node as the fallback. Moving the whole
Claude Code runtime to Bun was the next step the user asked for, and the work turned up
two facts that the fallback design hid:

- `bun script.mjs` run from inside a repository loads that repository's `bunfig.toml`
  `preload` and its `.env`. The hook command ADR-017 wrote passed no flag against that,
  so a cloned repository could run its own code inside `b-path-guard` (and make it allow
  everything) or put `.env` values into hook child processes. `--no-env-file
--config=/dev/null` turns both off (checked with a preload that writes a marker file:
  no marker, no `.env` value, stdin and exit codes unchanged).
- Under Bun the snapshot CLI marked every untracked regular file `unreadable`, because
  `createReadStream` rejects a Buffer path, so a clean candidate came back incomplete.
  The CLI now opens the Buffer path and streams the descriptor, which both runtimes
  accept, and its output under Node is byte-identical (a parity probe against the
  previous commit checks 14 fixtures under both runtimes).

## Decision

- Claude Code runs every script b-agentic ships for it with Bun: hooks, the status
  line, the helper CLIs named in skills, the kernel and the docs, the tests and
  validators, and the repository's own dev tooling (`bun install` with a `bun.lock`,
  `bun run quality`, a `.husky` hook, CI). Node is no longer a Claude Code prerequisite.
- Every managed and documented command is `bun --no-env-file --config=/dev/null <script>`.
  [ADR-028](ADR-028-short-helper-wrappers.md) refines this: the helpers a model types are called through short wrappers that carry these flags.
  The generator renders the bare `bun`; the installer replaces it with the absolute path
  it found (symlinks kept, so a package-manager upgrade keeps working), because Claude
  Code's hook shell may not have `~/.bun/bin` on `PATH`.
- The installer refuses to install (also `--dry-run` and `--statusline-only`) without a
  Bun that runs the hardening flags, and an uninstall does not need Bun. There is no Node
  fallback: if Bun is removed later, the fail-closed guards (`onFailure: "block"`) block
  until it is reinstalled, which is the intended failure.
- A re-install retires exactly the entries the manifest recorded (plain `node`, or the
  ADR-017 bun-or-node form) and merges the new ones by exact command; the user's own
  hooks are never touched, and an unrecorded `node` entry for a managed script is kept
  and reported because it would fail without Node.
- `--js-runtime` and `B_AGENTIC_JS_RUNTIME` are removed.
- Pi stays on Node (Pi was later removed by [ADR-019](ADR-019-opencode-second-runtime.md)): its guard extension runs inside Pi's own process and imports the same
  hook modules, so those modules stay runtime-neutral (the snapshot parity probe and the
  Pi probes run under Node). Pi's generated text keeps `node ~/.pi/agent/b-agentic/...`
  through a glossary entry for the Bun prefix.
- `b-codex-review` runs the Codex plugin's companion script with `node` from `PATH`, the
  plugin's own runtime and the form the guard recognises. Missing Node ends the run as
  an unavailable plugin (exit 4), which falls back to `b-reviewer`.

## Consequences

- Hook, status line, and helper start-up cost drops with Bun's faster start
  (see ADR-017's measurements), and no hook loads a repository's Bun configuration.
- Bun is a hard dependency of the Claude Code runtime, and Bun releases are a new source
  of breakage: CI pins the Bun version, and a hook that fails to start blocks rather than
  allowing the call.
- The kernel stays inside its size budget by trimming two phrases; Pi's kernel text is
  restored to its earlier wording through glossary entries so Pi output is unchanged.
- Dev tooling (Prettier, markdownlint, lint-staged, husky) runs through Bun
  (`bun node_modules/.bin/<tool>`), so a machine with no Node can run `bun run quality`;
  CI keeps Node for the Pi probes and for the Codex plugin's own script (the fake plugin in the hooks probe
  runs with it).

Evidence: [`install.sh`](../../install.sh),
[`claude/bin/b-state.mjs`](../../claude/bin/b-state.mjs), and
[`claude/configs/settings.template.json`](../../claude/configs/settings.template.json).

## Rejected

- Keeping the ADR-017 Node fallback: the user decided against it, and it hid the
  failure.
- `bun` from `PATH` in hook commands: the hook shell's `PATH` is uncertain.
- A managed `bunfig.toml`: `--config=/dev/null` is simpler and cannot be overridden by a
  repository file.
- `bun build --compile` binaries (109 MB each) and a hook daemon: unchanged from ADR-017.
- Moving Pi to Bun: Pi runs in Node.
