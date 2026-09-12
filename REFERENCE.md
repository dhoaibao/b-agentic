# b-agentic operational reference

[Back to the public overview](README.md)

This is the operational source of truth for installation, lifecycle, safety,
MCP, package, and verification behavior behind the concise
[README.md](README.md). The installed path map and managed-versus-user-owned
boundary live in [adapters/pi/configs/README.md](adapters/pi/configs/README.md); this reference
owns the operations performed on those paths.

## Install

Default install for Pi:

```bash
curl -fsSL https://raw.githubusercontent.com/dhoaibao/b-agentic/main/install.sh | bash
```

Default install writes b-agentic files and Pi configuration only. Pi CLI installation and upgrade run automatically without prompts. In an interactive TTY, the default install opens a dependency-free component picker with all optional groups selected: MCP support, Pi integrations, and the Dracula theme. Core files and required tooling remain selected. Use Up/Down, Space, Enter, or Escape to navigate, toggle, continue, or cancel. Redirected, CI, `TERM=dumb`, and explicit `--update`, `--sync`, or `--uninstall` runs remain non-interactive.

### Release transport

The installer never clones a repository and never requires `git`. The piped
`main` script is a bootstrap only: it downloads `b-agentic.tar.gz` and its
SHA-256 checksum from the GitHub release, requires a 64-character hexadecimal
digest match, rejects any archive entry outside the published payload contract
(absolute paths, `..` traversal, dotfiles, symlinks, and non-file members),
extracts to a temporary directory, and re-executes every state change from
`bash <payload>/install.sh --source-dir <payload>`. State is therefore never
changed by the piped script itself.

The verified payload is installed into `~/.b-agentic` (override with
`B_AGENTIC_DIR`): `install.sh`, `VERSION`, `skills/`, `references/`,
`adapters/pi/`, and `tooling/install/`. Installation is transactional — staged,
backed up, and rolled back on failure or interruption — and refuses to replace
an `install.sh` that lacks the `# B_AGENTIC_INSTALLER` managed marker. A legacy
`git clone`-based checkout at `~/.b-agentic` (detected via `.git`) moves aside
wholesale to `~/.b-agentic.backup.<timestamp>` and the reported backup path;
it is preserved verbatim and never merged. `~/.b-agentic/install.sh --sync`
re-downloads and verifies the latest release before refreshing that directory;
`--update` and `--uninstall` reuse the installed source without any download.
If no release is published yet, the bootstrap fails with an actionable error —
the first `vYYYY.MM.DD` tag must be pushed before the installer can run
(see the [release procedure](docs/release-procedure.md)).

### Standalone Markdown preview install

After the public immutable `v0.1.2` tag has been published, a user who wants
only the inline Markdown preview can run:

```bash
curl -fsSL https://raw.githubusercontent.com/dhoaibao/b-agentic/v0.1.2/adapters/pi/scripts/install-preview-markdown.sh | bash -s -- v0.1.2
```

The trailing `v0.1.2` argument must match the bootstrap URL tag; the
installer accepts only `vX.Y.Z` release refs. This exact future command fetches
only `adapters/pi/packages/preview-markdown/extensions/b-agentic-preview-markdown.ts` from the `v0.1.2` tag,
validates it, and atomically installs it as
`${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}/extensions/b-agentic-preview-markdown.ts`.
It preserves unrelated extension files and Pi configuration and does not
install any other b-agentic extension or dependency. Run `/reload` in the
current Pi session after installation. The tag is not claimed to be published
or executable from this repository state; wait until `v0.1.2` exists publicly.

After the package is published, the same canonical extension can also be
installed through Pi:

```bash
pi install npm:@dhoaibao/preview-markdown
```

The npm package contains only the preview extension and package-facing
documentation; the raw GitHub installer remains the version-pinned alternative
and does not install the broader b-agentic bundle. Maintainers should use the
[standalone preview package publishing procedure](docs/publish-preview-markdown.md)
for validation and release steps.

No `AGENTS.md` entry is required because the extension self-registers its
`preview_markdown` tool and prompt metadata. An optional local `AGENTS.md` note
may remind future sessions to prefer `preview_markdown` when appropriate.

The preview defaults to Tokyo Night Moon. In a TUI session,
`/preview-markdown:theme` opens a native Moon/Day selector and immediately refreshes existing visible previews; restored previews use the current global theme without mutating stored session entries. `/preview-markdown:render <prompt>` requests a one-response preview, and `/preview-markdown:list` lists the 20 most recent successful previews on the active branch for source copying. This cap affects only the selectable list and does not delete session history. The selected theme is persisted globally in
`<Pi agent dir>/b-agentic/preview-theme.json`, not in a project file or Pi
`settings.json`. Escape cancels without changing the preference. A malformed
or missing preference safely falls back to Moon, and a persistence failure is
reported without changing the active behavior. Preview entries do not retain a
stored palette.

For professional or shared environments, pin both the bootstrap script and the
installed release to a reviewed `vYYYY.MM.DD` release tag instead of consuming
whatever release is currently latest:

```bash
export B_AGENTIC_REF=<vYYYY.MM.DD>  # an existing release tag
curl -fsSL "https://raw.githubusercontent.com/dhoaibao/b-agentic/${B_AGENTIC_REF}/install.sh" | bash -s -- --ref="${B_AGENTIC_REF}"
```

Useful flags:

- `--dry-run` previews changes.
- `--replace-memory` replaces an existing managed kernel file.
- `--uninstall` removes managed files.
- `--ref=vYYYY.MM.DD` downloads that release tag's verified tarball instead of the latest release; commit SHAs and SemVer tags are no longer installable pins.
- `--sync` re-downloads the latest verified release into the installed source and syncs managed Pi skills, kernel, and first-party extensions only.
- `--update` installs or updates RTK, CodeGraph, Bun, Pi, Dracula theme, and Pi extensions without re-downloading the release.

Requirements: `bash`, `curl`, `tar`, `mktemp`, a SHA-256 tool (`sha256sum` or
`shasum`), and Python 3.11+. `git` is not an installer prerequisite; the
optional Dracula theme is skipped with a warning when `git` is missing. Bun,
Pi, RTK, and CodeGraph
are installed or updated automatically without dependency opt-in variables or
prompts. Bun-backed MCP servers use `bunx`, which resolves and
caches their packages on first use. Modern shell tools are not
installed or updated automatically because they generally require sudo; the
readiness report provides a platform-specific install hint.

Installer output stays newline-based for redirected and CI runs. On an interactive
TTY the default install uses a dependency-free ASCII component picker followed by
its stage indicator (both disabled for `TERM=dumb`), then prints a concise success
and attention summary. A later picker run reconciles checked groups and leaves
unchecked managed groups untouched; explicit uninstall is still required to remove
those groups.

## RTK (Rust Token Killer)

The installer downloads and runs the RTK install script from its `master`
branch when RTK is missing and reruns it to refresh an existing installation.
This is a remote shell script; only use it if you
trust the RTK repository. RTK is required for b-agentic sessions; installation
fails if it cannot be installed.

Once installed, agents use RTK for every command family it supports, including
local discovery. For unsupported command families, they prefer modern shell
tools (`rg`, `fd`/`fdfind`, `eza`/`exa`, `bat`/`batcat`, `sd`, `jq`) and fall back
only when the replacement is missing or a worse fit. Regular repository-local
commands are auto-allowed regardless of that recommendation, including routine
build, test, package, dependency, and script automation; RTK does not bypass
protections for explicit destructive or privileged commands, external/shared
mutations, protected paths, outside-project paths, or unscoped Git content
reads. Explicit destructive commands are denied. Build and test tools can
execute code from the current repository, so this permission layer is not a
process sandbox. Use Pi's sandbox integration or an isolated environment when
running genuinely untrusted code.

Examples:

```bash
rtk rg pattern src
fd -t f '.ts$'
eza -la
rtk git status
rtk cargo test
rtk pytest -q
```

Meta commands:

```bash
rtk gain            # Token savings analytics
rtk gain --history  # Recent command savings history
rtk --help          # Supported command families
rtk proxy <cmd>     # Optional raw execution with RTK tracking
```

RTK also provides an optional rewrite-only Pi extension:

```bash
rtk init --agent pi --global
```

This improves transparent command rewriting but does not replace b-agentic's
permission extension or approval policy. b-agentic does not install it
automatically.

Verification: `rtk --version`, `rtk gain`, `which rtk`.

## CodeGraph MCP agent

b-agentic writes a default [CodeGraph](https://github.com/colbymchenry/codegraph)
entry that runs `codegraph serve --mcp` with `CODEGRAPH_TELEMETRY=0`. Interactive
the installer installs CodeGraph with:

```bash
curl -fsSL https://raw.githubusercontent.com/colbymchenry/codegraph/main/install.sh | sh
```

Existing CodeGraph installations are refreshed with `codegraph upgrade`. Select CodeGraph when repository-wide architecture, dependency/call-flow, route-to-handler, impact, or affected-test analysis is central to the task and likely valuable; use an available index for that question and initialize an absent index only for that concrete qualifying question. Do not select or initialize CodeGraph merely because a task spans files.

## Managed MCPs

The installer writes recommended entries for CodeGraph, Context7, Brave Search,
Firecrawl, and Playwright. Servers use lazy lifecycle through the
adapter's proxy tool, so they are not eagerly started or injected into context.
The template sets a global `settings.requestTimeoutMs` of 30000 milliseconds
(30 seconds). API keys are user-supplied and are written only to user config,
never tracked templates.

| MCP          | Use                                                                    | Local readiness                                                                                                                                                    |
| ------------ | ---------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| CodeGraph    | Architecture, dependency/call flows, impact, and affected tests        | `codegraph` CLI; initialize only for a concrete qualifying repository-wide architecture, dependency/call-flow, route-to-handler, impact, or affected-test question |
| Context7     | Versioned framework and API facts                                      | `CONTEXT7_API_KEY`                                                                                                                                                 |
| Firecrawl    | Primary public research, bounded extraction, papers, and GitHub lookup | Bun (`bunx`) and `FIRECRAWL_API_KEY`                                                                                                                               |
| Brave Search | Independent corroboration and specialized current search               | Bun (`bunx`) and `BRAVE_API_KEY`                                                                                                                                   |
| Playwright   | Live browser, visual, console/network, and e2e evidence                | Bun (`bunx`)                                                                                                                                                       |

The installer does not eagerly start MCP servers or initialize repositories;
Bun is installed or refreshed automatically, while Bun-backed MCP packages are
resolved and cached by `bunx` on first use. b-agentic selects CodeGraph when
repository-wide architecture, dependency/call-flow, route-to-handler, impact,
or affected-test analysis is central to the task and likely valuable; it uses
an available index for that question and initializes an absent index only for
that concrete qualifying question. It does not select or initialize CodeGraph
merely because a task spans files. b-agentic automatically installs or updates
RTK, CodeGraph, and Bun; modern shell tools remain user-installed. Use `scripts/mcp-doctor.sh --session-tools` to verify the active
session has RTK. Use `--allow-degraded` to inspect status without failing.

When live network/process activity is approved,
`scripts/mcp-doctor.sh --probe-schemas` explicitly starts or connects to each
configured server and compares its current tool inventory with the canonical
operation policy. The Playwright MCP server enables testing capabilities
(`--caps=testing`), providing locator generation (`browser_generate_locator`)
and state verification tools (`browser_verify_*`). The probe covers only the
five managed servers; user-added servers (such as `serena` or other third-party
tools) fail closed through generic custom-tool approval with no argument
validation. Template MCP package specifications are unversioned, so `bunx`
resolves latest at runtime. The doctor never acquires OAuth tokens. Run it
after MCP package updates and before release candidates. Add `--suggestions`
for human-readable review records and `--suggestions-json=<path>` for a
machine-readable report; suggestion mode never edits policy or configuration.

## Capability contract and local status

The installed [`~/.pi/agent/b-agentic/references/capabilities.yaml`](references/capabilities.yaml)
contract records activation triggers, prerequisites, local readiness, fallbacks,
and non-sensitive status signals for every managed package, MCP server, and
first-party extension. `/b-status` renders a local, read-only snapshot from
that contract using only package-listing, extension-file, MCP-config-file
existence, and non-sensitive launcher metadata. It does not parse `mcp.json`,
inspect environment/API-key values, start MCP servers, authenticate providers,
run browser probes, or persist prompts, code, URLs, secrets, or usage telemetry.
Managed MCP configuration and credentials remain unknown or unverified in this
snapshot; use `mcp-doctor` or an explicitly approved operation for readiness
that requires config content or authentication. The snapshot complements
`mcp-doctor` and approved live/browser evidence rather than replacing them.

## Pi integration and packages

Pi discovers native skills from `~/.pi/agent/skills/` and MCP configuration from
`~/.pi/agent/mcp.json` through `pi-mcp-adapter`. b-agentic preserves user-owned
configuration and reports every managed change.

Pi does not provide native MCP. b-agentic installs MCP server entries into
`~/.pi/agent/mcp.json` and expects the community package `pi-mcp-adapter` to load
them. The installer runs `pi install npm:pi-mcp-adapter` automatically.

For long-session compaction continuity, b-agentic can install the optional
`pi-observational-memory` package. The installer runs `pi install npm:pi-observational-memory` automatically. Use it as the sole automatic
memory/compaction layer rather than combining it with another such extension.
Its V3 model does not read V2 settings or memory entries; after upgrading from
V2, migrate the settings and start a clean Pi session.

b-agentic installs the `@sreetej510/pi-usage` extension automatically.

b-agentic installs `@gotgenes/pi-anthropic-auth` automatically for Anthropic authentication support.

b-agentic installs `@juicesharp/rpiv-todo` automatically at the latest release. This Pi package provides the todo tool, `/todos` command, and persistent overlay; the kernel guides lightweight task tracking for non-trivial multi-step work when available, without requiring it for small or routine tasks or imposing workflow orchestration, persistence, or telemetry.

b-agentic installs `pi-intercom` automatically as an optional coordination package and installs
`@juicesharp/rpiv-ask-user-question` at the latest release for structured planning and execution decisions and blockers.
Skill questions group 1–4 related questions, offer 2–4 concrete options with
concise trade-offs, suffix the first recommended option with ` (Recommended)`,
and rely on the extension's automatic custom-answer row. Do not author `Other`,
`Type something.`, or `Next`. If the package or interactive UI is unavailable,
fall back to one focused plain-text question and retain the user-input attention
signal. After checking `pi list`, the installer runs `pi update --extensions`
after reconciling required Pi packages. Uninstall removes managed config and
extension files but not any package.

Pi has no native permission model, so b-agentic installs a first-party set of
purpose-specific `tool_call` extensions under `~/.pi/agent/extensions/`:

- `b-agentic-permissions.ts` for shell/filesystem policy.
- `b-agentic-mcp-permissions.ts` for managed MCP and custom-tool approval.
- `b-agentic-auto-mode.ts` for confirmed automatic approval with explicit-deny protection.
- `b-agentic-sync.ts` for in-session refresh commands.

Helpers under `adapters/pi/extensions/b-agentic-support/` are not discovered as
standalone Pi extensions. Pi enforces managed MCP and RTK policy from
`references/mcp_operations.yaml` and `references/kernel.template.md`.

## Installed configuration layout

See [Pi Configuration Layout](adapters/pi/configs/README.md) for the installed path
map and managed-versus-user-owned boundary. This reference owns the lifecycle
that acts on those paths: merge, preservation, backup, restore, and uninstall
behavior is documented in the installation and package sections above and
below.

Installers merge MCP configuration rather than replace it: unrelated user
servers survive, prompted secrets use a private input pipe, and API-key
placeholders remain in the tracked template. On normal install/upgrade and
`--update` (not `--sync`), b-agentic shallow-clones the Dracula Pi theme
repository, validates `dracula.json`, copies it to the theme cache, and links
`~/.pi/agent/themes/dracula.json` to that cached copy without changing Pi theme
settings or selection. User files and unrelated symlinks at the theme destination
are preserved with a warning. Uninstall removes only unchanged managed content
and symlinks, restores recorded user backups, preserves modified or
symlinked files, and never removes installed packages, including `@gotgenes/pi-anthropic-auth` and `@juicesharp/rpiv-todo`.

## Review and commit gates

`b-review` is the changed-code review gate: it independently assesses a candidate
snapshot (tracked plus relevant untracked/derived content), acceptance, required
check freshness, security, and residual risk, then returns exactly one verdict —
`READY FOR PR`, `READY WITH FOLLOW-UPS`, or `NEEDS FIXES`. `READY WITH FOLLOW-UPS`
requires an explicit accepted disposition and cannot waive safety evidence;
`NEEDS FIXES`, a stale verdict, a missing baseline, a changed snapshot, an
untracked change, or a skipped or failed check blocks shipping. Corrections are
reverified and return for another review. Review completion, task acceptance, and
commit creation are distinct. No automatic commit or push occurs without an
explicit user commit request; once requested, `b-commit` executes its
snapshot-verified plan without a second confirmation. Repository-required commit
preparation — same-day changelog maintenance only when repository rules require
it for an authorized commit — precedes the final candidate snapshot.

`b-pr-summary` also reviews or rewrites supplied PR prose without requiring Git
history or a code-review disposition. Editorial feedback is not a changed-code
review disposition; commit-backed fact checking remains explicitly scoped.

## In-session refresh

`/b-sync` confirms, pulls the installed b-agentic checkout, and syncs only
managed Pi skills, kernel, and first-party extensions before reloading Pi. It
does not install packages or change MCP configuration. `/b-update` runs without
an additional confirmation and updates RTK, CodeGraph, Bun, and Pi extensions without pulling b-agentic;
Bun-backed MCP packages are resolved by `bunx` on first use. It then reloads Pi.
Both commands require an interactive session and take no arguments.

## Safety and approvals

The permission extension:

- auto-allows regular repository-local commands, including routine build, test, package, dependency, and script automation
- asks before external/shared mutations, dangerous-but-approvable actions, protected reads, and unclassified or unsafe MCP operations
- blocks prohibited destructive Git and Docker families and protected native writes/edits
- inspects compound shell segments and strips `env`/`sudo`/`rtk` wrappers and `git -C` option prefixes before matching
- fails closed for ambiguous expansion, opaque interpreters, outside-project executables, protected paths, and approval-required actions without UI; b-auto-mode is the only opt-in exception for `ask` decisions and never overrides `deny`
- auto-allows classified CodeGraph operations, plus classified read-only and safe conditional-read MCP operations; other custom tools require approval

This is a command-policy guard, not a process sandbox: approved build and test
tools may execute repository-controlled code. Use Pi sandboxing or an isolated
environment for genuinely untrusted code. b-agentic never pushes changes.

Native `read`/`edit`/`write` is preferred for routine repository work. Select
CodeGraph when repository-wide architecture, dependency/call-flow,
route-to-handler, impact, or affected-test analysis is central to the task and
likely valuable. Use an available index for that question and initialize an
absent index only for that concrete qualifying question; do not initialize it
merely because work spans files.

## Repository quality checks

Repository-development tooling is separate from the installed runtime. From the
repository root, install the locked Node tools and pinned Python quality tools:

```bash
npm ci --no-fund --no-audit
python3 -m pip install -r requirements-dev-quality.txt
npm ci --prefix pi --no-fund --no-audit
```

`npm run quality` (or `bash scripts/quality-check.sh`) enumerates tracked files
with `git ls-files` and runs check-only ESLint, Prettier, Ruff lint and format
checks, ShellCheck, Markdownlint, and strict Pi TypeScript checks. It never
rewrites files. The tracked `.husky/pre-commit` hook is enabled by `npm ci`'s
`prepare` script and uses lint-staged to run the same applicable checks only on
staged files; it does not run the behavioral or installer suite and does not
rewrite the commit.

The quality check intentionally leaves generator-owned delivery outputs and the
JSON-compatible YAML registries to their existing synchronization and structural
validators. CI runs the complete quality check on Ubuntu and macOS before the
release validation and b-agentic audit lanes.

## Validation

Run the narrowest applicable checks from the repository root:

```bash
python3 tooling/generate/registry_sync.py --check
scripts/validate-skills.sh
scripts/validate-skills.sh --release
scripts/b-agentic-audit.sh
scripts/smoke-install.sh
scripts/mcp-doctor.sh
scripts/mcp-doctor.sh --allow-degraded
scripts/skill-doctor.sh
```

The validation suite proves generated sync, install safety, Pi config shape,
skill payloads, MCP operation policy regression, and local MCP readiness
blockers. The default routing check is static. The opt-in `--routing`
effectiveness lane and prompt-effectiveness runner make model calls and require
human review against their included rubrics.

Prompt effectiveness is opt-in and human-scored because it makes potentially
billable model calls and is nondeterministic. Validate inputs without model
calls, then pin provider, model, and thinking level for comparisons:

```bash
python3 adapters/pi/tests/prompt_effectiveness.py --validate-inputs
python3 adapters/pi/tests/prompt_effectiveness.py --allow-model-calls --provider=<provider> --model=<model> --thinking=<level> --label=baseline > baseline.json
python3 adapters/pi/tests/prompt_effectiveness.py --routing --validate-inputs
python3 adapters/pi/tests/prompt_effectiveness.py --routing --allow-model-calls --provider=<provider> --model=<model> --thinking=<level> --label=baseline-routing > baseline-routing.json
```

Browser evidence is opt-in. When requested, b-browser writes only under an
explicitly approved local evidence directory and never claims screenshot
coverage unless a screenshot was collected. Live MCP schema probing is also
opt-in because it starts processes and network activity.

## Repository map

- `skills/` — canonical prompts, registry metadata, and generated skill assets.
- `adapters/pi/` — Pi integration, configuration, extensions, and Pi smoke tests.
- `references/` — kernel and canonical MCP policy.
- `tooling/generate/` — registry synchronization and renderers.
- `tooling/install/` — shared installer implementation.
- `tooling/validate/` — validation harness.
- `tests/smoke/` — installer and Pi smoke coverage.
- `scripts/` — validation, doctor, smoke, and acceptance entrypoints.
- `docs/decision_design.md` — evidence-backed repository decisions.
