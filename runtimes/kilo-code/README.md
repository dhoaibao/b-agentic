# Kilo Code Runtime Adapter

Adapter-owned files for the Kilo Code runtime. Shared skills and contracts stay runtime-neutral; Kilo Code-specific paths, config merge behavior, and caveats live here.

## Adapter-owned files

- `configs/README.md` — Runtime layout, install paths, and MCP readiness for Kilo Code users.
- `configs/mcp.user.template.json` — MCP servers + permissions + `skills.paths` injection merged into `~/.config/kilo/kilo.jsonc`.
- `scripts/install.sh` — Thin runtime driver sourced by `install.sh`. Handles kernel install, agent profiles, skills sync, and MCP config merge.
- `scripts/validate.sh` — Adapter-specific validator checked by `scripts/validate-skills.sh`.
- `tests/smoke.sh` — Smoke lane for `tests/smoke/install.sh`. Covers install, uninstall, merge, collision, and API-key injection.
- `agents/` — Optional subagent profiles (b-explore, b-research, b-review, b-verify) installed as read-only helpers.
- `kernel.md` — Generated from `references/contract/kernel.template.md`. Do not hand-edit.

## Kilo Code specifics

- **Config file:** `~/.config/kilo/kilo.jsonc` (global), `./kilo.jsonc` or `.kilo/kilo.jsonc` (project).
- **MCP key:** `mcp` (not `mcpServers`).
- **Skills discovery:** `~/.config/kilo/skills/` is injected into `skills.paths` in `kilo.jsonc`.
- **No command wrappers:** Kilo Code exposes skills natively through the Agent Skills spec.
- **Agent profiles:** Markdown files with YAML frontmatter placed in `~/.config/kilo/agents/`.
- **JSONC merge:** The installer parses JSONC but writes plain JSON on merge. User comments may be stripped.

See `configs/README.md` for full install layout and caveats.
