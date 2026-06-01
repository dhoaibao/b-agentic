# b-agentic - Maintainer Guide

Guidelines for editing this source repository. This file is maintainer guidance, not an installed runtime kernel.

## Product Direction

`b-agentic` is a workflow harness, not just a skill suite. Its job is to give AI agents a small, reliable operating system for developer work: route by intent, apply safety gates, ground claims in evidence, verify before claiming completion, and hand off between phases without losing context.

The product vision is multi-runtime support. Claude Code is the reference runtime, but shared behavior must remain portable across OpenCode, Codex CLI, Antigravity CLI, Cursor, and Zed through runtime adapters.

The guiding standard is: slim, strong, usable. Prefer fewer concepts, clearer contracts, and validation that protects real behavior. Remove layers that only make agents carry more ceremony; keep tooling that improves correctness, install reliability, or cross-runtime delivery.

## Scope

- `README.md` stays brief: overview, install, supported runtimes, skills, layout, and validation.
- Root `CLAUDE.md` is shared repo guidance, not a Claude-Code-only authoring spec.
- Claude Code is the reference runtime; OpenCode, Codex CLI, Antigravity CLI, Cursor, and Zed are supported through runtime adapters.
- Shared runtime-facing content under `skills/` and `references/contract/` must stay runtime-neutral.
- Runtime-specific paths, kernel filenames, install layout, wrappers, and caveats belong under `runtimes/<name>/`.
- Do not create a second root reference surface.

## Source Of Truth

- `skills/registry.yaml` owns skill metadata and generated `SKILL.md` frontmatter.
- `skills/*/prompt.md` owns canonical skill bodies.
- `runtimes/registry.yaml` owns runtime metadata.
- `references/contract/kernel.template.md` owns the shared kernel source.
- `skills/*/SKILL.md` and `runtimes/*/kernel.md` are committed generated assets.
- Registry files must stay in the JSON-compatible YAML subset so repo tooling can use Python standard library only.
- Registry order is user-facing unless a renderer explicitly narrows it.
- Do not hand-edit generated assets when a source file owns the content.

## Authoring Rules

- Shared prompts and contract prose must not hardcode runtime-specific behavior or paths.
- Use `{{skill_support_path}}` for skill-local support files and `{{runtime_reference_root}}` for installed shared references.
- Add explicit read gates at the step that uses a contract section.
- Keep long schemas, rubrics, and edge-case protocols in `references/contract/`, not prompts.
- Optional `skills/*/reference.md`, `examples.md`, and `scripts/` are support material, not a second root doc surface.
- In `skills/*/prompt.md`, `CLAUDE.md` means the active runtime kernel, not this maintainer guide.

## Key Paths

- `skills/` - skill sources and generated delivery assets
- `runtimes/` - runtime adapters, configs, scripts, and smoke lanes
- `references/contract/` - detailed runtime contract
- `tooling/generate/` - renderers and doc generators
- `tooling/install/` - shared installer core
- `tooling/validate/` - shared validation harness
- `tooling/conformance/` - status/handoff policy checker
- `tooling/scenarios/` - golden workflow scenario runner
- `tests/smoke/` - shared smoke harness
- `tests/internal/` - internal conformance and scenario fixtures
- `runtimes/runtime-template/` - scaffold for new runtime adapters

## Skill Assets

`skills/<name>/prompt.md` is required and canonical. `SKILL.md` is generated. `reference.md`, `examples.md`, and `scripts/` are optional.

Generated `SKILL.md` files use frontmatter from `skills/registry.yaml`. Required fields are `name` and `description`; common optional field is `argument-hint`. Add runtime-sensitive optional fields only when needed, and do not add legacy compatibility metadata unless a plan explicitly requires it.

Keep skill descriptions trigger-focused, write imperative steps, and add support files only when they materially improve token hygiene or reuse.

## Runtime Adapters

Adapter directories own runtime-specific kernels, config templates, install hooks, wrappers, smoke tests, and caveats:

```text
runtimes/<name>/
├── kernel.md
├── configs/
├── scripts/
└── tests/
```

`install.sh` is the bootstrap entrypoint. Shared install behavior lives in `tooling/install/common.sh`; runtime-specific behavior lives in `runtimes/<name>/scripts/install.sh`.

`scripts/validate-skills.sh` wraps shared validation plus runtime validators. `scripts/validate-skills.sh --release` adds installer smoke and internal release checks. `scripts/smoke-install.sh` runs the smoke suite directly.

Do not add a runtime without updating generation, validation, smoke coverage, and docs in the same change.

## Sync Rules

- Skill metadata: edit `skills/registry.yaml`, rerun `python3 tooling/generate/registry_sync.py`, then update hand-authored docs if the public surface changed.
- Skill prompt: edit `skills/*/prompt.md`, rerender generated assets, and update support docs only when needed.
- Kernel behavior: edit `references/contract/kernel.template.md`, rerender affected `runtimes/*/kernel.md`, and keep docs aligned.
- Runtime behavior: update `runtimes/registry.yaml` and affected adapter docs/scripts together.
- Keep `README.md` overview-level.

## Validation

Before merging runtime-facing changes:

1. Rerun `python3 tooling/generate/registry_sync.py` when generated surfaces are affected.
2. Run `scripts/validate-skills.sh`.
3. Run `scripts/validate-skills.sh --release` when install, runtime, wrapper, kernel delivery, output policy, scenario, or release-readiness behavior changed.
4. Run `bash scripts/internal-check-conformance.sh --self-test tests/internal/conformance/cases.json` while iterating on output policy, conformance, readiness, or status/handoff behavior.
5. Run `bash scripts/internal-check-scenarios.sh --self-test tests/internal/scenarios/cases.json` while iterating on routing, phase handoffs, readiness, or workflow behavior.
6. Run `scripts/smoke-install.sh` directly only when you need installer smoke coverage by itself.
7. Codex CLI install, validation, and smoke paths require Python 3.11+ `tomllib`.
8. Antigravity CLI exposes `/b-*` through `~/.gemini/antigravity-cli/skills/`; MCP config lives at `~/.gemini/antigravity-cli/mcp_config.json` and remote MCP entries use `serverUrl`.
9. Confirm shared content stayed runtime-neutral and docs changed with public or maintainer surface changes.
10. Confirm prompt read gates use `{{skill_support_path}}/...` or `{{runtime_reference_root}}/...`, not hardcoded delivery paths.

## Review Checklist

- Correct source layer, not generated asset?
- Shared content still runtime-neutral?
- Runtime-specific details under `runtimes/<name>/`?
- Registry-driven generation and docs still synced?
- No new root-level documentation sprawl?
