# Host Compatibility Reference

Per-host facts for the runtime-neutral b-agentic suite, confirmed from official
documentation only (P0 research gate). Any point that could not be confirmed is
recorded as **deferred**, never guessed. Adapters are built only for facts
recorded here; see the [decision record](decision_design.md) for the
runtime-neutral reversal and `references/permissions.yaml` for the shared
declarative permission data.

Enforcement stance (user-ratified): adapters ship **declarative configuration
only** (the agreed basic level). Every verified host also has a deterministic
pre-tool hook able to hard-block tool calls; those hook contracts are documented
here as capability facts, but v1 ships no shared hook scripts.

## Evidence summary

| Host        | Instruction file                             | Skills                                                         | MCP config                                                     | Declarative permissions                                               | Pre-tool hook                                   |
| ----------- | -------------------------------------------- | -------------------------------------------------------------- | -------------------------------------------------------------- | --------------------------------------------------------------------- | ----------------------------------------------- |
| Claude Code | `CLAUDE.md`                                  | `.claude/skills/*/SKILL.md`                                    | `.mcp.json` (project root)                                     | `settings.json` permissions, first match wins, deny strongest         | `hooks.PreToolUse[]`, exit 2 blocks             |
| Codex       | `AGENTS.md` (+ `$CODEX_HOME/AGENTS.md`)      | `${CODEX_HOME:-$HOME/.codex}/skills`                           | `~/.codex/config.toml` `[mcp_servers.*]`                       | `sandbox_mode` + `approval_policy` + Starlark execpolicy              | `hooks.json` PreToolUse, trust-gated, deny-only |
| OpenCode    | `AGENTS.md`                                  | `.opencode/skills/*/SKILL.md` (+ Claude/agent-compatible dirs) | `opencode.json` `"mcp"` object                                 | `opencode.json` `"permission"` object, last matching rule wins        | plugin `tool.execute.before`, throw blocks      |
| Antigravity | `~/.gemini/GEMINI.md` + `.agents/rules/*.md` | `.agents/skills/<name>/SKILL.md`                               | `.agents/mcp_config.json` / `~/.gemini/config/mcp_config.json` | deny/ask/allow `action(target)` lists, Deny > Ask > Allow             | `hooks.json` PreToolUse, `decision` required    |
| Pi          | `~/.pi/agent/AGENTS.md`                      | `~/.pi/agent/skills/<name>/SKILL.md`                           | `~/.pi/agent/mcp.json`                                         | `b-agentic-permissions.ts` tool_call handler, full shell tokenization | `tool_call` handler `{block:true}`              |

Portable SKILL.md frontmatter intersection across all five hosts: `name` +
`description` only. Host-specific keys (Claude Code `allowed-tools`, Codex
`metadata.short-description`, OpenCode `license`/`compatibility`/`metadata`)
belong to per-adapter rendering, not the shared file.

## Portable permission semantics

Precedence direction is **not uniform** across hosts, so
`references/permissions.yaml` expresses deny/ask/allow as unordered sets and
each adapter emits its host-native ordering:

- Claude Code: deny > ask > allow, first match wins; a deny at any scope cannot
  be overridden upward.
- Antigravity: Deny > Ask > Allow (ask beats allow: `command(*)` in ask defeats
  `command(git)` in allow).
- OpenCode: last matching rule wins (opposite of Claude Code).
- Codex: no per-pattern list; OS sandbox (`sandbox_mode`), `approval_policy`,
  and Starlark execpolicy `prefix_rule` with `decision="allow"|"prompt"|"forbidden"`.
- Pi: TypeScript classifier with full shell tokenization (strongest declarative
  enforcement of the five).

## Command-matching strength (accepted downgrade, per host)

The Pi classifier tokenizes shell input (aware of `sh -c`, pipes, `&&`, and
environment prefixes). No other host documents that, which is the accepted
downgrade for v1:

- **Pi:** full shell tokenization (`adapters/pi/extensions/b-agentic-support/shell.ts`).
- **Claude Code:** compound-command aware — docs state it recognizes `&&`, `||`,
  `;`, `|`, `|&`, `&`, and newlines and requires each subcommand of a compound
  command to match rules independently. Docs explicitly warn argument-constraining
  Bash patterns are fragile (flags, redirects, env vars) and recommend denying
  network CLIs plus using hooks. No `sh -c`/env-prefix claim.
- **Antigravity:** literal word-by-word prefix match by default; `command(regex:...)`
  opts into regex. Windows PowerShell/cmd commands that cannot be cleanly
  word-split require an exact match.
- **OpenCode:** glob-style prefix patterns only (`"git *"`, `"rm *"`); no
  documented tokenization. The plugin hook fully recovers enforcement in
  principle, but v1 ships declarative config only.
- **Codex:** not pattern-based. Ordered-token execpolicy matching plus OS-level
  sandboxing; a hardcoded `BANNED_PREFIX_SUGGESTIONS` list can never be
  allow-listed and already blocks the shells/interpreters (`bash -c`, `python`,
  `node`, …), `git`, `sudo`, `rm`, `env`, and `<pm> run` bypass class.

## Claude Code

- **Instruction:** `CLAUDE.md` at project and global scope; `rules/*.md` topic
  scoped. Precedence: managed > local > project > global; a deny at any level
  cannot be overridden upward. (code.claude.com/docs/en/settings-reference,
  /claude-directory)
- **Skills:** `.claude/skills/*/SKILL.md` (project), `~/.claude/skills/*/SKILL.md`
  (personal). Frontmatter `name`, `description`, optional `allowed-tools`;
  `${CLAUDE_SKILL_DIR}` resolves scope-independently. (/skills)
- **MCP:** `.mcp.json` at project root, key `mcpServers`, entries
  `{"type":"http","url":...}` or `{"type":"stdio","command":...,"args":[...]}`;
  personal servers in `~/.claude.json`; env-var references supported for
  secrets. (/mcp-quickstart)
- **Permissions:** `settings.json` -> `permissions.{allow,ask,deny}` +
  `defaultMode`; syntax `Bash(npm run *)`, `Read(./.env)`, `Read(./secrets/**)`.
  Deny also hides matching files from read/edit tools in all modes. Scopes:
  `~/.claude/settings.json`, `.claude/settings.json`,
  `.claude/settings.local.json`, managed settings. (/permissions)
- **Hook:** `settings.json` `hooks.PreToolUse[]` =
  `{matcher:"Bash",hooks:[{type:"command",command:"..."}]}`; script reads
  `tool_input` JSON on stdin; exit 2 blocks (stderr becomes agent feedback),
  exit 0 defers to the normal permission flow; JSON
  `hookSpecificOutput.permissionDecision:"deny"` also supported. Hooks merge
  across settings files. (/hooks, /hooks-guide)

## Codex CLI

- **Instruction:** project `AGENTS.md` concatenated from project root down to
  cwd; global `$CODEX_HOME/AGENTS.override.md` first, else
  `$CODEX_HOME/AGENTS.md` (default `~/.codex`), joined with a
  `\n\n--- project-doc ---\n\n` separator. `project_doc_max_bytes` caps project
  docs only and never disables the global file.
  (github.com/openai/codex `codex-rs/core/src/agents_md.rs`,
  `codex-home/src/instructions/mod.rs`)
- **Skills:** SKILL.md with frontmatter `name` (max 64 chars) + `description`,
  optional `metadata.short-description`; discovery scans to depth 6; official
  install path `${CODEX_HOME:-$HOME/.codex}/skills`. (`skills/src/parser.rs`)
- **MCP:** `[mcp_servers.<name>]` in `~/.codex/config.toml`; stdio `command`,
  `args`, `[mcp_servers.<name>.env]`; remote streamable HTTP `url`; per-server
  `enabled_tools`/`disabled_tools`. Config writes are allowed only to user
  `config.toml`, preserving comments/formatting.
  (`protocol/src/config_types.rs`, `config/src/config_toml.rs`,
  `app-server/src/config_manager_service.rs`)
- **Permissions:** `sandbox_mode` = `read-only` (default) | `workspace-write` |
  `danger-full-access`; `[sandbox_workspace_write] network_access`;
  `approval_policy` = `untrusted` | `on-request` (default) | `granular` |
  `never`; execpolicy Starlark `prefix_rule(pattern=..., decision=...)`.
  `BANNED_PREFIX_SUGGESTIONS` can never be persisted as allow rules.
  (`core/src/exec_policy.rs`, `execpolicy/README.md`)
- **Hook:** `hooks.json` with top-level `description` + `hooks` mapping event ->
  `[{matcher:"^Bash$", hooks:[{type:"command", command, timeout_sec, ...}]}]`;
  matcher is a regex. Events: PreToolUse, PostToolUse, UserPromptSubmit,
  SessionEnd (SessionStart unconfirmed). stdin snake_case
  (`tool_name`, `tool_input`, `hook_event_name`, `cwd`, …); stdout camelCase
  `hookSpecificOutput.permissionDecision` nested. Runtime constraints: `ask` is
  rejected, bare `allow` is rejected unless `updatedInput` is present, `deny`
  requires a non-empty reason — the only clean decision is deny-with-reason, so
  the ask tier must come from `approval_policy`/execpolicy `decision="prompt"`.
  Trust gate: handlers install only for Trusted/Managed hooks (or
  `bypass_hook_trust`); a freshly installed hook silently does nothing until the
  user trusts it — the installer must say so.
  (`hooks/src/schema.rs`, `hooks/src/engine/command_runner.rs`,
  `hooks/src/engine/output_parser.rs`, `tui/src/startup_hooks_review.rs`)
- **Deferred (D2a):** the official discovery location for Codex `hooks.json`
  (`$CODEX_HOME/hooks.json` vs project path vs config pointer) was not
  confirmable. Blocks nothing under the declarative-only decision.

## OpenCode

- **Instruction:** precedence at startup: (1) local files walking up from cwd —
  `AGENTS.md` (preferred) then `CLAUDE.md`, first match per category; (2) global
  `~/.config/opencode/AGENTS.md`; (3) `~/.claude/CLAUDE.md` unless disabled.
  Extra files via `"instructions":[...]` globs in `opencode.json`. (/rules)
- **Skills:** native `skill` tool with progressive disclosure
  (`<available_skills>` injected; full content loaded on demand). Discovery
  paths: `.opencode/skills/<name>/SKILL.md` and
  `~/.config/opencode/skills/<name>/SKILL.md` (native), plus
  `.claude/skills/`/`~/.claude/skills/` and `.agents/skills/`/`~/.agents/skills/`
  (cross-host compatible). Strictest frontmatter: recognized fields `name`
  (required, 1-64 chars, `^[a-z0-9]+(-[a-z0-9]+)*$`, must equal the containing
  directory name), `description` (required, 1-1024 chars), optional
  `license`/`compatibility`/`metadata` (string-to-string); unknown fields
  ignored. Declarative skill gating via `permission.skill` pattern maps; custom
  commands (`.opencode/commands/*.md`) are a separate mechanism. (/skills,
  /commands, /permissions)
- **MCP:** `opencode.json` / `opencode.jsonc`
  (`"$schema":"https://opencode.ai/config.json"`; global
  `~/.config/opencode/opencode.json`; `OPENCODE_CONFIG` loads between global and
  project). Local:
  `{"type":"local","command":[...],"enabled":true,"environment":{...}}` with
  optional `cwd`/`timeout`; remote:
  `{"type":"remote","url":...,"enabled":true}`. (/config, /mcp-servers)
- **Permissions:** `"permission"` object; coarse per-tool
  (`{"*":"ask","bash":"allow"}`) or granular pattern maps
  (`"bash":{"git *":"allow","git push *":"deny"}`); agent-scoped overrides under
  `agent.<name>.permission`. **Last matching rule wins.** (/permissions)
- **Hook:** JS/TS plugins auto-loaded from `.opencode/plugins/` (project) and
  `~/.config/opencode/plugins/` (global); `tool.execute.before` hook can throw
  to block or mutate `output.args` to rewrite (official examples: `.env` read
  protection, `shescape` wrapping). Also `tool.execute.after`,
  `permission.asked`, `file.edited`, `session.*`. (/plugins)

## Antigravity

- **Instruction:** global `~/.gemini/GEMINI.md`; workspace
  `.agents/rules/*.md` at workspace or git root (legacy `.agent/rules`
  supported). **Rules files are limited to 12,000 characters each** — this is
  the binding constraint for the kernel ceiling (lowered from 12,800 bytes by
  user decision). Per-rule activation: Manual (@mention), Always On, Model
  Decision, Glob. `@filename` references resolve relative to the rules file.
  (/docs/rules-workflows)
  - Deferred (D4): third-party sources claim root `AGENTS.md` support; the
    official rules doc documents only `GEMINI.md` + `.agents/rules/`. The
    adapter targets the official paths only.
- **Skills:** `.agents/skills/<name>/SKILL.md` (workspace),
  `~/.gemini/config/skills/<name>/SKILL.md` (global); legacy `.agent/skills`
  supported. Frontmatter `description` required, `name` optional (defaults to
  folder name). Docs call skills an open standard (agentskills.io).
  (/docs/skills)
- **MCP:** workspace `.agents/mcp_config.json`, global
  `~/.gemini/config/mcp_config.json`, key `mcpServers`; transports: stdio
  `command` + `args` + `env` + `cwd`, or remote `serverUrl`. Legacy
  `url`/`httpUrl` fields are explicitly NOT supported. Optional `headers`,
  `disabled`, `disabledTools`, OAuth (`authProviderType:"google_credentials"`
  or `oauth{clientId,clientSecret}`); callback
  `https://antigravity.google/oauth-callback`. (/docs/mcp)
- **Permissions:** `action(target) resource` rules in deny/ask/allow lists,
  precedence Deny > Ask > Allow. Actions: `read_file`, `write_file`, `read_url`,
  `execute_url`, `command`, `unsandboxed`, `mcp(server/tool)`. Implicit rules:
  write implies read; deny read implies deny write. Unconfigured actions default
  to Ask. CLI file: `~/.gemini/antigravity-cli/settings.json` ->
  `{"permissions":{"allow":[],"deny":[],"ask":[]}}`. Official deny examples
  match this suite's intent: `command(rm -rf)`, `command(sudo)`,
  `command(regex:curl .*)`, `write_file(.git/)`, `write_file(/home/user/.ssh)`.
  (/docs/permissions, /docs/cli/permissions)
  - Deferred (D3): the Antigravity IDE/2.0 permissions config file path; only
    the CLI settings path is documented as a file (IDE permissions are a
    Settings UI surface).
- **Hook:** `hooks.json` in `.agents/` (workspace) or `~/.gemini/config/`
  (global); events PreToolUse, PostToolUse, PreInvocation, PostInvocation,
  Stop. `matcher` is a regex over tool name; handler
  `{type:"command", command, timeout}` (default 30s), `enabled:false` disables
  without deleting. stdin JSON in, JSON out (camelCase); PreToolUse output
  requires `decision` = `allow|deny|ask|force_ask|deny_unless_prior_grant`,
  optional `reason` and `permissionOverrides`. Tool names include `run_command`,
  `view_file`, `write_to_file`, `replace_file_content`,
  `multi_replace_file_content`, `read_url_content`, `ask_question`. (/docs/hooks)

## Pi

- **Instruction:** kernel at `~/.pi/agent/AGENTS.md`.
- **Skills:** `~/.pi/agent/skills/<name>/SKILL.md`.
- **MCP:** template `~/.pi/agent/b-agentic/templates/mcp.user.template.json`
  merged into user-owned `~/.pi/agent/mcp.json`; extensions under
  `~/.pi/agent/extensions/`. (adapters/pi/configs/README.md)
- **Permissions + hook:** `b-agentic-permissions.ts` `tool_call` handler
  returning `{block:true}`, failing closed when `!ctx.hasUI`; the classifier in
  `adapters/pi/extensions/b-agentic-support/shell.ts` provides the only full shell
  tokenization in the suite. `adapters/pi/` retains this deterministic
  enforcement and consumes `references/permissions.yaml` so the classifier and
  the portable data cannot drift.

## Multi-host coexistence (installer obligations)

Skill and instruction directories overlap by design across hosts; the installer
must avoid double-loading when multiple adapters are installed:

- OpenCode reads `.claude/skills/` (Claude Code's path) and `.agents/skills/`
  (Antigravity's path) in addition to its own — installing Claude Code or
  Antigravity alongside OpenCode double-registers every shared skill unless the
  OpenCode adapter defers to an already-installed adapter or writes only to
  `.opencode/skills/`.
- OpenCode also falls back to `~/.claude/CLAUDE.md` for instructions, so
  installing both adapters can double-load the kernel document as well as
  skills (same class of problem as the skills overlap).
- Codex joins global and project instruction docs rather than choosing one;
  a globally installed kernel plus a project-level install would both load.
- Every adapter registers in the uninstall manifest so `install.sh` removal
  leaves no stray files, preserving the existing manifest semantics.

## Research provenance

Verified 2026-09 via the P0 gate against official documentation: Claude Code
(code.claude.com/docs), Codex (github.com/openai/codex `codex-rs` sources),
OpenCode (opencode.ai/docs), Antigravity (antigravity.google/docs), Pi
(repository sources). Deferred points: D2a (Codex hooks.json location), D3
(Antigravity IDE permissions file), D4 (Antigravity root AGENTS.md). No host
ships deferred for skills, MCP, or declarative permissions.
