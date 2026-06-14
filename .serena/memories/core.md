# Core

- Slim workflow kernel for coding agents across Claude Code, OpenCode, and Codex CLI.
- User-facing overview: `README.md`; maintainer guidance: `CLAUDE.md`.
- Source layers: `skills/` owns skill sources/generated assets; `runtimes/` owns runtime adapters/smoke lanes; `references/contract/` owns shared runtime-neutral contract; `tooling/` owns generation/install/validation code; `tests/smoke/` owns installer smoke tests.
- Generated assets: `skills/*/SKILL.md`, `runtimes/*/kernel.md`, OpenCode command wrappers. Prefer editing source prompts/registries/templates, then regenerate.
- Registry/source details: read `mem:conventions` for authoring rules, `mem:tech_stack` for tooling, `mem:task_completion` for verification expectations.