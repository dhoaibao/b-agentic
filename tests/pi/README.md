# Pi permission integration probe

This gate checks the proposed Pi runtime extensions against a local stub model
and a local stdio MCP server. No model credentials or external MCP connections
are needed. It exercises main-session decisions, read-only specialist tool
visibility and policy, protected paths, MCP proxy denial, and dynamically
registered direct MCP tools. The probe does not test interactive approval UI,
real providers, or the seven production MCP servers.

Run `bash tests/pi/permission-probe.sh --setup` to install the six unpinned
extension packages into the ignored `node_modules/.pi-migration-probe` profile
and execute the cases. Setup downloads public npm packages. Subsequent offline
runs use `bash tests/pi/permission-probe.sh`. The isolated profile sets
`PI_CODING_AGENT_DIR`, `PI_OFFLINE`, `PI_SKIP_VERSION_CHECK`, and `PI_TELEMETRY`;
the stub provider never contacts its dummy endpoint. The script writes its
fixture policy, agent, and JSON event traces only under the ignored profile.

Installed package declarations use bare `npm:` names. Re-running setup updates
the installed extensions to their latest available releases. The probe does
not establish live readiness for production MCP servers or real providers.

`tooling/validate/run.sh --release` runs this probe together with the verify-gate
and snapshot probes. It skips them with a message when `pi` or the probe profile
is absent, unless `B_AGENTIC_REQUIRE_PI_PROBES=1` (set in CI), which fails on a
missing `pi` and runs `--setup` for a missing profile.

## Verify-gate probe

`bash tests/pi/verify-gate-probe.sh` loads only `pi/extensions/b-verify-gate.ts`
and a scripted local model (`gate-stub-provider.ts`) with `pi -ne`. It needs no
npm packages, credentials, or network. It checks that an edit followed by no
shell command earns exactly one reminder and one extra model turn, while
edit-then-shell, prose-only, and no-edit runs earn none.

## Input-image-preview probe

`bash tests/pi/input-image-preview-probe.sh` loads `pi/extensions/b-input-image-preview.ts`
with the same scripted local model and `pi -ne`. It needs only Pi and jq: no npm
packages, credentials, or network. A test-only extension
(`input-image-preview-cases.ts`) runs unit cases at session start: path
extraction, clipboard-path labels, the recent-preview list behind `/image`, its
argument parsing, popup-slot ownership including closing an open popup on
shutdown, and the 20 MB read cap. The probe requires a minimum case
count so a partial run cannot pass. It then checks that a non-TUI run loads
without an error, leaves the prompt unchanged, and does not claim `/image`.
Thumbnails, the popup, and mouse handling need a real terminal and are not
covered.

## Snapshot probe

`bash tests/pi/snapshot-probe.sh` loads `pi/extensions/b-candidate-snapshot.ts`
with the same scripted local model and throwaway git repositories. It needs
only Pi, git, and jq. It checks that the tool digests equal the canonical
manual `git diff` procedure, that repeated calls agree and an edit changes the
fingerprint, that a subdirectory cwd does not narrow the candidate, that
untracked files (including binary files and symlinks) are hashed from their
bytes, that protected paths (same-size edits made unreadable, a literal `hex:`
name, a protected parent directory, raw non-UTF-8 names) are listed
without being hashed, diffed, or returned and mark the snapshot incomplete, that submodules are listed and
never inspected, that an applicable clean filter (including one hidden behind an empty `filter=`
value) is refused without running, that inherited `GIT_*_PATHSPECS` variables
cannot disable the exclusions, that a partial clone is refused without fetching,
that a repository directory name ending in whitespace resolves correctly and a non-UTF-8 root or working directory is refused,
that `.git/index` is untouched, and that a non-repository fails. Set `SNAPSHOT_PROBE_KEEP=1` to keep the work directory.
