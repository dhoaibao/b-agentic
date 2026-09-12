# b-agentic

**A slim personal workflow kernel for the Pi coding agent. b-agentic and Pi are one integrated product.**

b-agentic routes work to focused skills, preserves safety gates, uses the right
evidence, and verifies before claiming completion. It installs a compact Pi
kernel, native skills, first-party extensions, and recommended MCP configuration.

- **[Read the operational reference](REFERENCE.md)** for installation details,
  package lifecycle, MCP readiness, safety behavior, and validation. `/b-status` provides a local, read-only capability snapshot
without reading MCP configuration contents or API-key values, starting MCP
services, authenticating providers, or claiming session usage.
- **[See the installed Pi layout](adapters/pi/configs/README.md)** for managed paths and
  user-owned configuration boundaries.
- Maintainer and project context: [AGENTS.md](AGENTS.md),
  [CHANGELOG.md](CHANGELOG.md), and [decision design](docs/decision_design.md).

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/dhoaibao/b-agentic/main/install.sh | bash
```

The piped script is only a bootstrap: it downloads the release tarball for the
current `vYYYY.MM.DD.N` release, verifies its SHA-256 checksum, validates every
archive entry against the published payload contract, and then re-executes all
state changes from inside that verified bundle. `git` is not required.
In an interactive terminal, the installer opens a component picker with the
current optional features selected by default; redirected and CI runs keep the
non-interactive install path. See [REFERENCE.md](REFERENCE.md) for the picker
controls and lifecycle behavior.

For reviewed pins, flags, package lifecycle, readiness, the standalone
Markdown preview install, and the preview package route, see
[REFERENCE.md](REFERENCE.md). The preview package also has its own
[package-facing guide](adapters/pi/packages/preview-markdown/README.md).

## How b-agentic works

Each request routes to one active phase rather than mixing planning, building,
validation, and shipping. The workflow is solo: one agent loads one skill at a
time, asks the user directly for material decisions, and never spawns a
coordinating peer. See [REFERENCE.md](REFERENCE.md) for operational, safety,
MCP, and installation behavior.

| Phase | Skills | Purpose |
|---|---|---|
| **Decide** | `b-plan`, `b-research`, `b-design`, `b-debug` | Resolve ambiguity, gather outside facts, diagnose runtime causes, or define a frontend standard. |
| **Build** | `b-frontend`, `b-diagram`, `b-implement`, `b-init`, `b-refactor` | Make the smallest approved change. |
| **Validate** | `b-test`, `b-browser`, `b-agentic-audit`, `b-review` | Confirm tests, browser evidence, repository conformance, and changed-code quality. |
| **Ship** | `b-commit`, `b-pr-summary` | Create explicitly requested local commits or write PR copy from local history. |

## Skills

<!-- generated:skills-table:start -->
| Skill | Phase | Use |
|---|---|---|
| `b-plan` | Decide | Figure out what to do when scope or approach is fuzzy, then produce an execution-ready plan |
| `b-research` | Decide | Fetch outside truth: docs, API facts, comparisons, or recent evidence |
| `b-design` | Decide | Create or refresh docs/DESIGN.md as a frontend design standard |
| `b-frontend` | Build | Implement contextual frontend/UI code, styling, responsive behavior, interactions, visual refreshes, and landing pages |
| `b-diagram` | Build | Create validated, portable technical architecture and flow diagrams from explicit facts |
| `b-implement` | Build | Make the scoped non-UI change from an approved plan or a small direct request |
| `b-init` | Build | Initialize or refresh repo-local agent instruction docs |
| `b-refactor` | Build | Rename, extract, move, inline, simplify, or delete behavior-preserving code |
| `b-debug` | Decide | Confirm the runtime root cause and produce an evidence-backed fix handoff without editing product code |
| `b-test` | Validate | Write or fix unit, integration, contract, and simulated-DOM tests |
| `b-browser` | Validate | Collect real-browser, visual, screenshot, live UI, or e2e evidence |
| `b-agentic-audit` | Validate | Audit b-agentic repository conformance, health, skill/kernel quality, and currentness |
| `b-review` | Validate | Review changed code |
| `b-commit` | Ship | Split working-tree changes into cohesive commits from an explicit user request |
| `b-pr-summary` | Ship | Write commit-backed PR copy or review and rewrite supplied PR prose |
<!-- generated:skills-table:end -->

Invoke a skill explicitly with Pi's native `/skill:<name>` command. The usual
path is:

```text
/skill:b-plan [goal] -> approve -> /skill:b-implement -> /skill:b-test -> /skill:b-review
```

## Learn more

- [Operational reference](REFERENCE.md) — install/update/uninstall behavior,
  packages, MCPs, safety, and validation.
- [Pi configuration layout](adapters/pi/configs/README.md) — installed paths and
  managed-versus-user-owned boundaries.
- [Standalone preview package](adapters/pi/packages/preview-markdown/README.md) —
  preview-only package and version-pinned installation documentation.
- [Decision design](docs/decision_design.md) — evidence-backed repository
  decisions.
