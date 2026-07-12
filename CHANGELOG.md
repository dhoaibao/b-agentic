# Changelog

All notable shipped revisions of b-agentic are recorded here. Version numbers match `pyproject.toml` and immutable Git tags of the form `vYYYY.MM.DD` (or `vYYYY.MM.DD.N` for same-day revisions).

## Unreleased

### Removed

- Remove the Cursor runtime adapter and all Cursor-specific install, doctor, acceptance, policy, and docs surfaces.
- Remove `references/contract/shell-tools.md`; the required shell-tool and RTK preferences now live in the always-loaded kernel template.

### Security

- Gate Firecrawl external-mutation, local-upload, monitor-lifecycle, and Playwright page-mutating MCP tools in Claude Code managed permission templates.
- Add canonical `references/contract/mcp_operations.yaml` as the single source for managed MCP tool classes, with generated contract table and closed-world adapter policy regression.
- Encode classified Firecrawl/Playwright operations in Codex (`enabled_tools` + approval modes) templates with static closed-world regression; keep public support tiers at `guidance-shell-only` until live runtime enforcement is proven.
- Document version-bound server-level trust rationale for fully trusted managed MCP servers.

### Changed

- Label runtime `--active` probes as simulated protocol evidence, not live acceptance.
- Add operator attestation recorder plus `scripts/verify-release-evidence.sh` for attestation/static/tag checks without overstating production readiness.
- Bind release attestations to the requested runtime and require exact HEAD git revisions (`unknown` is not release-eligible).
- Require resolvable `runtime.cli_version` plus registry-matching `support_tier` / `mcp_enforcement` on release attestations; reject `production_claim: excluded` runtimes; require `--scoped-claim=shell-gated-only` for shell-gated-only runtime verification.
- Reject arbitrary `--evidence` paths that cannot bind to a registered runtime; require registered `runtime.name` on every attestation.
- Introduce explicit runtime support tiers in `runtimes/registry.yaml` and the README capability matrix.
- Expand simulated acceptance coverage to Pi harness command construction.
- Add outcome-focused skill routing fixtures for high-risk phase boundaries.
- Publish a richer runtime capability matrix in the README.
- Move optional shell-tool/RTK preferences out of the always-loaded kernel into `references/contract/shell-tools.md`.
- Simplify `b-summary` and make `b-design` structure an adaptable checklist rather than a forced skeleton.

## 2026.06.24

- Baseline package version aligned with the 2026-06-24 development snapshot.
