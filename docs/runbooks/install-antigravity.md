# Install antigravity

Install, update, or remove b-agentic for the Antigravity CLI (`agy`). This is
opt-in: a plain `./install.sh` still targets Claude Code only. Design and gaps
are in [ADR-025](../decisions/ADR-025-antigravity-second-runtime.md).

## Prerequisites

- `agy` 1.5.12 (the verified version; it is reported, never enforced).
- `bun` and `python3`. `jq` is not needed. Install the other tools by
  [install-prerequisites](install-prerequisites.md).
- Quit `agy` before installing, because `agy` rewrites `settings.json` while it
  runs.
- `~/.gemini` must be a real directory or absent (the installer creates it); a
  symlink is refused. The installer writes only under `~/.gemini` and never
  touches `~/.claude` or `~/.claude.json` on an Antigravity run.

## Steps

1. Preview the changes. Nothing is written.

   ```bash
   ./install.sh --dry-run --runtime=antigravity
   ```

2. Install for the Antigravity CLI only, or for both runtimes (Claude Code
   first, then `agy`).

   ```bash
   ./install.sh -y --runtime=antigravity
   ./install.sh -y --runtime=both
   ```

3. Optional: choose optional components (`datagrip`, `excalidraw`, `drawio`,
   `notion`). Both flags are additive and repeatable, and the choice is
   remembered in the manifest.

   ```bash
   ./install.sh -y --runtime=antigravity --with=excalidraw
   ./install.sh -y --runtime=antigravity --without=excalidraw
   ```

4. Optional: `--force` replaces a file you modified or one b-agentic did not
   install, after a backup. It touches managed files only and never replaces
   your own MCP server or `b-agentic` hook group.

   ```bash
   ./install.sh -y --runtime=antigravity --force
   ```

5. Optional: shell commands. `agy` Auto mode needs a terminal sandbox that some
   hosts lack, so every command would ask. The install therefore adds one allow
   rule, `command(*)`, by default; the managed `ask` and `deny` rules (for
   example `git push` and force pushes) still win over it. The choice is
   remembered in the manifest.

   ```bash
   ./install.sh -y --runtime=antigravity --no-shell-auto   # leave it out, or remove the one this installer added
   ./install.sh -y --runtime=antigravity --shell-auto      # add it back
   ```

6. Start `agy` again so skills, agents, the rule, hooks, permissions, and MCP
   servers load.

What lands where, all under `~/.gemini`:

- `config/skills/`, `config/agents/`, `config/rules/b-agentic.md`.
- `config/b-agentic/` holds `bin/`, `hooks/` (including `b-agy-hook.mjs`),
  `references/`, the manifest `install.json`, and `backups/`.
- The hook group `b-agentic` in `config/hooks.json`, servers in
  `config/mcp_config.json`, and permissions in `antigravity-cli/settings.json`.

Running the install again changes nothing. A file you edited since the last
install is kept and reported as modified.

## Verify

This is a manual smoke test you run yourself; it is not part of the automated
checks. The automated coverage is `bash tests/install/antigravity-install-probe.sh`,
which uses sandbox homes and never starts `agy`.

1. Restart `agy` in a scratch workspace.
2. Confirm the `b-agentic` rule, the `b-*` skills, and the `b-*` agents are
   loaded.
3. Ask `agy` to read a `.env`-style path. The hook should deny it.
4. Ask `agy` to run `git push`. It should ask before running.
5. With shell auto on, ask `agy` to run `ls`. It should run without a prompt, and
   `cat .env` in the scratch workspace should still be denied by the hook.

## Troubleshooting

- **A failing managed hook blocks every tool.** Roll back with
  `./install.sh --runtime=antigravity --uninstall`, restart `agy`, and report the
  hook error. If you edited the `b-agentic` hook group (or it was never recorded),
  uninstall keeps that group and, so the group still works, the `b-agentic/` scripts
  and the manifest too; it says so in a warning. Remove the `b-agentic` group from
  `~/.gemini/config/hooks.json`, then run the uninstall again to finish.
- **The install is refused before any write** when `~/.gemini`, `config`,
  `antigravity-cli`, or a managed directory is a symlink; when a config file
  (`hooks.json`, `mcp_config.json`, `settings.json`) is malformed JSON or is a
  link that resolves outside `~/.gemini` (a managed payload file linked outside
  `~/.gemini` is refused too); or when the Bun path or home path would
  need shell quoting in the hook command (use paths without spaces or special
  characters). A symlinked config file that stays under `~/.gemini` is written
  through.
- **`kept ... (modified since install)` or `(not installed by b-agentic)`** means
  the file differs from what the manifest recorded. Keep your edit, or pass
  `--force` to replace it after a backup.
- **`kept your existing 'b-agentic' hook group` or MCP server** means yours differs
  from the managed one; remove it and install again to use the managed one.
- **`--statusline-only` is refused with `--runtime=antigravity`**, and any other
  `--runtime` value is refused. `--shell-auto` and `--no-shell-auto` are refused with
  `--runtime=claude` (also the default), with `--uninstall`, and together.
- **A command you did not expect ran without asking.** `command(*)` allows every
  command that has no `ask` or `deny` prefix, and the path guard does not stop a
  recursive read such as `grep -r` into a directory holding a `.env`. Turn it off with
  `--no-shell-auto`; a `command(*)` you added yourself stays and the installer warns.
- **The Codex review gate** needs the Claude Code Codex plugin (see
  [install-prerequisites](install-prerequisites.md)). Without it `b-review` uses
  the read-only `b-reviewer` subagent.

## Rollback and uninstall

A plain `./install.sh --uninstall` removes only the Claude Code install. To
remove the `agy` install, name the runtime:

```bash
./install.sh --runtime=antigravity --uninstall
./install.sh --runtime=both --uninstall   # both runtimes
```

Uninstall removes only the files, hook group, servers, and permission rules the
manifest recorded (including a `command(*)` this installer added, never yours) and
that are still unmodified; modified files stay with a warning. A kept `b-agentic` hook group keeps `b-agentic/` and the manifest until
you remove the group and uninstall again. Backups under `~/.gemini/config/b-agentic/backups/` are kept.

## Not ported or unverified

From ADR-025, so do not expect these:

- The status line is not ported; `--statusline-only` is Claude Code only.
- Whether a hook `command` expands `$HOME` is unverified, so the installer writes
  absolute paths.
- Per-agent MCP scoping cannot be enforced: any subagent can call a permitted MCP
  tool.
- Compaction survival of injected context, parallel workers in separate git
  worktrees, and the user skills folder location (beyond `~/.gemini/config/skills`,
  which is assumed) are unverified.
