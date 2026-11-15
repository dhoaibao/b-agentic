# ADR-017: Managed hooks and status line may run under Bun, with Node as the fallback

- Status: Accepted
- Date: 2026-11-15

## Context

Claude Code starts one process per hook event, and a hook that blocks work
(`b-path-guard`, `b-codex-guard`) sits on the path of every file and shell tool call.
Measured on one Linux machine (medians of 20 runs): a bare `node -e 0` costs 27 ms and
each hook 30 to 44 ms, so a Bash call paid about 74 ms of hook time and a Read about
41 ms; most of that is Node's own startup. `bun -e 0` starts in 5 ms and the same hook
files run in 10 to 18 ms under it. Merging hooks saves nothing (each event and tool
already starts one hook process), and the V8 compile cache measured no gain.

The Pi runtime imports the same hook modules in process
([ADR-011](ADR-011-pi-second-runtime.md)), so any non-JavaScript hook would duplicate
the security logic and need a parity corpus.

## Decision

Keep the hooks, CLIs, and the status line as the shared JavaScript they are. The
installer chooses how Claude Code launches them:

- `--js-runtime=auto|node|bun` on `tooling/install/claude_install.py`, with
  `B_AGENTIC_JS_RUNTIME` as its default so `./install.sh` (which does not parse the
  flag) can pass it. `auto`, the default, uses a working `bun` found on `PATH` and
  otherwise `node`; `bun` is refused when none works; `node` keeps today's commands.
- The generator and `settings.template.json` still render `node "<script>"`. The
  installer rewrites the managed hook and status line commands to
  `if [ -x '<bun>' ]; then exec '<bun>' "<script>"; else exec node "<script>"; fi`.
  The fallback keeps a fail-closed hook (`onFailure: "block"`) working if `bun` is
  removed after install, instead of blocking every file tool until a reinstall.
- A runtime change is an ordinary re-install: the recorded managed entry is retired
  (it is still exactly what was recorded) and the new one is merged by exact command,
  so the user's own hooks and status line are never touched.
- The shared modules load less: `b-protected.mjs` holds the protected-path rules so the
  path guard and the spec-context hook skip the snapshot CLI, and `b-codex-guard` loads
  the snapshot CLI only for a guarded command.

## Consequences

- A Bash call's hook time drops from about 74 ms to about 25 ms and a Read's from
  about 41 ms to about 12 ms when `bun` is present; Node-only installs gain the module
  trims (path-guard and codex-guard about 41 to 31 ms).
- `bun` is an optional dependency. The hook, statusline, and install probes run under
  both runtimes when `bun` is installed, and every case must give the same result.
- Hook decisions, exit codes, messages, and the snapshot schema are unchanged.
- Pi is unchanged beyond shipping `b-protected.mjs` with its other hook modules.

## Rejected

- Rust or another compiled fast path: about 10 ms more per call, but a second copy of
  the security parsers, a build and release step, and a parity corpus.
- A persistent hook daemon: Claude Code still spawns a command per hook, and a daemon
  that is down would make the fail-closed guard block every file tool.
- `bun build --compile`: 109 MB per binary and no faster than `bun file.mjs`.
- Requiring Bun: loses portability for no gain over the fallback.
- `./install.sh --js-runtime`: would widen the install script's argument surface; the
  environment variable and the Python flag cover it.
