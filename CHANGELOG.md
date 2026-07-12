# Changelog

All notable shipped revisions of b-agentic are recorded here. Version numbers match `pyproject.toml` and immutable Git tags of the form `vYYYY.MM.DD` (or `vYYYY.MM.DD.N` for same-day revisions).

## Unreleased

### Removed

- Remove the Cursor runtime adapter and all Cursor-specific install, doctor, acceptance, policy, and docs surfaces.
- Remove `references/contract/shell-tools.md`; the required shell-tool and RTK preferences now live in the always-loaded kernel template.
- Remove the Claude Code and Codex runtime adapters (folders, registry entries, install/uninstall, doctors, acceptance probes, policy checks, and docs), leaving Pi as the shipped runtime. The registry-driven installer, runtime folder layout, validation framework, and `runtimes/runtime-template/` scaffold remain in place so new runtimes can be added.

### Security

- Gate Firecrawl external-mutation, local-upload, monitor-lifecycle, and Playwright page-mutating MCP tools in Claude Code managed permission templates.
- Add canonical `references/contract/mcp_operations.yaml` as the single source for managed MCP tool classes, with generated contract table and closed-world adapter policy regression.
- Document version-bound server-level trust rationale for fully trusted managed MCP servers.

### Changed

- Introduce explicit runtime support tiers in `runtimes/registry.yaml` and the README capability matrix.
- Expand simulated acceptance coverage to Pi harness command construction.
- Add outcome-focused skill routing fixtures for high-risk phase boundaries.
- Publish a richer runtime capability matrix in the README.
- Move optional shell-tool/RTK preferences out of the always-loaded kernel into `references/contract/shell-tools.md`.
- Simplify `b-summary` and make `b-design` structure an adaptable checklist rather than a forced skeleton.

## 2026.06.24

- Baseline package version aligned with the 2026-06-24 development snapshot.
