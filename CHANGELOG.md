# Changelog

All notable shipped revisions of b-agentic are recorded here. Version numbers match `pyproject.toml` and immutable Git tags of the form `vYYYY.MM.DD` (or `vYYYY.MM.DD.N` for same-day revisions).

## Unreleased

### Security

- Gate Firecrawl external-mutation, local-upload, monitor-lifecycle, and Playwright page-mutating MCP tools in Claude Code and Cursor managed permission templates.
- Add canonical `references/contract/mcp_operations.yaml` as the single source for managed MCP tool classes, with generated contract table and closed-world adapter policy regression.
- Document Codex/OpenCode per-MCP-tool capability gaps.

### Changed

- Label runtime `--active` probes as simulated protocol evidence, not live acceptance.
- Add operator attestation recorder plus `scripts/verify-release-evidence.sh` for attestation/static/tag checks without overstating production readiness.
- Bind release attestations to the requested runtime and require exact HEAD git revisions (`unknown` is not release-eligible).
- Reject arbitrary `--evidence` paths that cannot bind to a registered runtime; require registered `runtime.name` on every attestation.
- Expand simulated acceptance coverage to Cursor and Pi harness command construction.
- Add outcome-focused skill routing fixtures for high-risk phase boundaries.
- Publish a richer runtime capability matrix in the README.

## 2026.06.24

- Baseline package version aligned with the 2026-06-24 development snapshot.
