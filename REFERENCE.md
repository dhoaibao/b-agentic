# b-agentic operational reference

[Back to the public overview](README.md)

This reference defines the installed native OpenCode workflow, lifecycle,
safety boundary, MCP configuration, and repository validation behavior.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/dhoaibao/b-agentic/main/install.sh | bash
```

The installer runs OpenCode's current curl installer (`curl -fsSL
https://opencode.ai/v2/install | bash`) and writes b-agentic assets to
`~/.config/opencode`. Because this intentionally tracks OpenCode updates, test
native config, permissions, agent, and command compatibility before relying on a
newly released major version. If the OpenCode installer cannot run, b-agentic
warns and still installs its local assets; install OpenCode manually, then rerun
`--update`. It installs the global kernel, generated skills, specialist agents, generated commands,
references, templates, snapshots, and manifest. It merges the managed
recommendations into `opencode.json` instead of replacing unrelated user keys. If
an existing `permissions` value is not a v2 rule array, it remains user-owned
and the installer warns that b-agentic's managed rules were not merged.

Useful flags:

- `--dry-run` prints planned commands and avoids writes.
- `--force` permits the installer's normal source-refresh path when applicable.
- `--replace-memory` replaces an existing non-managed global `AGENTS.md` after
  the caller expressly opts in; `--preserve-memory` keeps it.
- `--uninstall` removes unmodified managed OpenCode assets and managed config
  values; it preserves modified or symlinked assets.
- `--sync` refreshes managed assets from the installed b-agentic checkout and adds missing configuration values; existing user configuration values remain authoritative.
- `--update` refreshes the OpenCode CLI through its current curl installer without updating the b-agentic checkout.
- `--ref=<tag-or-commit>` selects a checkout ref for installation; only safe
  branch, tag, and commit-like names are accepted. `B_AGENTIC_REPO` accepts
  HTTPS, SSH, or local-path repository locations.

`B_AGENTIC_DIR`, `B_AGENTIC_REPO`, `B_AGENTIC_REF`,
`B_AGENTIC_OPENCODE_DIR`, and `B_AGENTIC_OPENCODE_CONFIG` support isolated
testing and controlled installs. OpenCode configuration is JSONC-compatible:
when only `opencode.jsonc` exists, the installer merges into that file; every
merge writes JSON after creating a backup, so comments are not preserved. A detected legacy runtime installation is only reported and never
modified.

See [OpenCode configuration layout](opencode/configs/README.md) for paths and
managed-versus-user-owned boundaries.

## Kernel, skills, commands, and delegation

OpenCode discovers the global kernel at `~/.config/opencode/AGENTS.md` and
skills below `~/.config/opencode/skills/`. The `skill` tool loads a `SKILL.md`;
the kernel requires one active skill at a time. Generated `/b-<skill>` commands
provide explicit routing. `skills/registry.yaml` and `skills/*/prompt.md` are
canonical; generated output must never be hand-edited.

The four specialist profiles are native `mode: subagent` definitions:
`b-planner`, `b-researcher`, `b-debugger`, and `b-reviewer`. The main session
uses native `subagent` delegation and treats each synchronous returned result as
evidence only. Specialist ordered permissions deny `edit`, `shell`, `subagent`,
and `question`; their named MCP access is limited to the relevant read-only tools.
`experimental.subagent_depth: 1` prevents nested delegation. The main session stays the only
user-facing worktree writer.

Every changed candidate requires fresh verification and a frozen
`b-reviewer` disposition before normal completion. Review never commits or
pushes.

## Native permissions

The generated `opencode.json` uses ordered OpenCode v2 `permissions` rules. Ordinary local
work, including native edits, is allowed, while named destructive commands such
as `git push`, `git pull`, `git reset --hard`, `git clean -f`, and `git branch -D`
are denied. Native `read` and `edit` rules deny likely-secret file patterns. External-directory
access and consequential MCP tools ask. Last matching permissions rule wins, so
rendered rule order is part of the configuration contract. User rules remain
last and authoritative: a user-supplied broad allow can intentionally override
a managed denial.

This is intentionally not a custom policy engine or process sandbox. Native
matching is glob-based: it does not normalize wrappers or compound shell
commands, and direct MCP permissions cannot inspect arguments. In particular,
an allowed shell command can bypass native `read` path rules; b-agentic does
not claim shell-level secret-path protection. The kernel's approval rules and a
suitable isolated environment remain necessary for untrusted code or sensitive
data.

## Managed MCPs

The template configures native OpenCode v2 `mcp.servers` entries for CodeGraph,
Context7, Brave Search, Firecrawl, Playwright, Mobbin, and shadcn. Code Mode is
disabled so direct OpenCode MCP tool names use `<server>_<tool>`; the Brave server is named `brave_search` to make
that convention unambiguous. API credentials are environment placeholders in
the tracked template and are never collected or written by the installer.

| MCP          | Primary use                                                                | Local prerequisite                  |
| ------------ | -------------------------------------------------------------------------- | ----------------------------------- |
| CodeGraph    | Repository-wide architecture, dependency/call-flow, impact, affected tests | `codegraph`                         |
| Context7     | Versioned framework and API documentation                                  | `CONTEXT7_API_KEY`                  |
| Brave Search | Independent current-web corroboration                                      | `bunx`, `BRAVE_API_KEY`             |
| Firecrawl    | Bounded public research and extraction                                     | `bunx`, `FIRECRAWL_API_KEY`         |
| Playwright   | Browser, visual, and e2e evidence                                          | `bunx`                              |
| Mobbin       | Optional product UI reference research                                     | native OAuth/account when requested |
| shadcn       | Optional component registry references                                     | `bunx`                              |

The native policy asks for an unknown managed-server tool name and allows only
listed read-only or intentionally selected conditional tool names. It asks for
upload, mutation, monitor, and authentication tool names. Some formerly
conditional operations are allowed by name because native OpenCode cannot
inspect their arguments. The installer does not use the inert v2 `instructions`
array; required workflow guidance lives in `AGENTS.md`.
Configuration never proves authentication, reachability, or use. Run
`scripts/mcp-doctor.sh` for local config/prerequisite status; it never starts
or authenticates MCP servers. Add `--allow-degraded` to report blockers without
a failing exit code.

## RTK and CodeGraph

RTK remains a required session prerequisite and is recommended for every
supported command family. When RTK does not support a command family, use the
best available shell tool (`rg`, `fdfind`, `batcat`, `eza`, `sd`, `jq`) or a
safe fallback. RTK does not bypass the kernel's destructive, protected,
outside-project, or external/shared boundaries.

Use CodeGraph only when repository-wide architecture, dependency/call flow,
route-to-handler, impact, or affected-test analysis is central. Use an existing
index, or initialize an absent index only for that concrete question.

## Validation

From the repository root:

```bash
python3 tooling/generate/registry_sync.py --check
scripts/validate-skills.sh
scripts/validate-skills.sh --release
npm run quality
scripts/b-agentic-audit.sh
scripts/smoke-install.sh
scripts/mcp-doctor.sh --allow-degraded
scripts/skill-doctor.sh
```

The validation suite checks generated assets, kernel budget, routing behavior,
capability and MCP contracts, decision-record citations, static readiness, and
installer lifecycle. Release validation adds sandboxed install smoke coverage.
`npm run quality` runs check-only formatting and language checks; it never
rewrites files. The changed candidate is frozen after checks, then independently
reviewed before normal completion.

## Repository map

- `skills/` — canonical prompts, registry metadata, and generated skills.
- `opencode/` — native agents, generated commands, configuration, installer, and validation.
- `references/` — kernel, capability registry, and MCP policy.
- `tooling/generate/` — synchronization renderer.
- `tooling/install/` — merge, backup, uninstall, and manifest helpers.
- `tooling/validate/` — static validation and readiness tools.
- `tests/smoke/` — sandboxed installer coverage.
- `scripts/` — validation, doctor, smoke, and acceptance entrypoints.
