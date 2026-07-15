# Changelog

All notable shipped revisions of b-agentic are recorded here. Version numbers match `pyproject.toml` and immutable Git tags of the form `vYYYY.MM.DD` (or `vYYYY.MM.DD.N` for same-day revisions).

## Unreleased

### Removed

- Remove the Cursor runtime adapter and all Cursor-specific install, doctor, acceptance, policy, and docs surfaces.
- Remove `references/contract/shell-tools.md`; the required shell-tool and RTK preferences now live in the always-loaded kernel template.
- Remove the Claude Code and Codex runtime adapters (folders, registry entries, install/uninstall, doctors, acceptance probes, policy checks, and docs), leaving Pi as the shipped runtime.
- Consolidate b-agentic around Pi by removing the runtime registry and template
  scaffold, promoting Pi integration assets to `pi/`, and simplifying installation
  and validation accordingly.

### Changed

- Expand simulated acceptance coverage to Pi harness command construction.
- Add outcome-focused skill routing fixtures for high-risk phase boundaries.
- Simplify `b-summary` and make `b-design` structure an adaptable checklist rather than a forced skeleton.
- Add opt-in, human-scored prompt-effectiveness scenarios for ambiguity, simplicity, surgical changes, and verified execution.
- Harden Pi permission handling for mixed MCP selectors, external session cleanup, and RTK-proxied legacy shell tools.
- Validate prompt-effectiveness inputs without model calls and detect RTK command-policy drift in session readiness checks.
- Classify MCP gateway operations canonically and require approval for managed connect/server-scoping lifecycle actions.
- Require Node-backed Pi permission-handler smoke coverage and add opt-in native routing and live MCP schema-drift evidence lanes.
- Detect newly added, unclassified RTK command families instead of checking compatibility in only one direction.

## 2026.06.24

- Baseline package version aligned with the 2026-06-24 development snapshot.
