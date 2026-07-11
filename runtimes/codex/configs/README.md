# Codex Runtime Layout

Adapter-owned layout for Codex.

## Install Layout

- Kernel memory: `~/.codex/AGENTS.md`
- Skills: `~/.codex/skills/<skill-name>/SKILL.md`
- Command governance rules: `~/.codex/rules/b-agentic.rules`
- Shared references: `~/.codex/b-agentic/references/contract/*.md`
- MCP template: `~/.codex/b-agentic/templates/mcp.user.template.toml`
- User config: `~/.codex/config.toml`

Codex install and smoke checks require Python 3.11+ for `tomllib`.

## Safety And MCP

The installer never overwrites `~/.codex/AGENTS.md` without `--replace-memory`. Plain install syncs skills, command governance rules, shared references, and a managed config block. User config outside the managed block is preserved.

MCP entries cover Serena, CodeGraph, Context7, Brave Search, Firecrawl, and Playwright. CodeGraph requires the `codegraph` CLI and a per-project `codegraph init`. API-key-backed tools require user-scope keys or matching shell environment variables. Playwright and other `pnpm dlx` entries require `pnpm` on `PATH`.

Codex uses managed command governance rules for baseline gates. The managed rules prompt before commits, pushes, pulls, reverts, dependency writes, and recursive removes; they forbid destructive git history/worktree commands and broad Docker resource deletion.

Support tier: `guidance-shell-only` (production claim: `shell-gated-only`). Managed templates encode Firecrawl/Playwright policy via Codex `enabled_tools`, `default_tools_approval_mode = "prompt"`, and per-tool `approval_mode = "approve"` for classified read-only tools from `references/contract/mcp_operations.yaml`. That encoding is validated statically only; do not claim operation-level runtime enforcement until versioned official-runtime evidence and live fresh-session tests prove read tools run without prompts, gated tools prompt, and unclassified tools cannot bypass the policy. Fully trusted managed servers remain server-level trusted with documented rationale.

## Validation

Use `scripts/validate-skills.sh` and `scripts/validate-skills.sh --release` from the repository root.
