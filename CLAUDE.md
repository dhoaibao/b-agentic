# b-agentic - Maintainer Guide

This file is maintainer guidance for editing this source repository. The public overview is `README.md`.

## Product Direction

b-agentic is a slim workflow kernel for coding agents. Keep only what improves routing, safety, evidence, verification, tool use, install reliability, or multi-runtime delivery.

The iron rule is: slim, strong, usable. Remove layers that mainly create ceremony.

## Scope

- `README.md` is the user-facing overview.
- `CLAUDE.md` is maintainer guidance.
- Shared runtime-facing content under `skills/` and `references/contract/` must stay runtime-neutral.
- Runtime-specific paths, config templates, wrappers, caveats, and smoke tests belong under `runtimes/<name>/`.
- Do not add root-level documentation surfaces.

## Source Of Truth

- `skills/registry.yaml` owns skill metadata and generated frontmatter.
- `skills/*/prompt.md` owns canonical skill bodies.
- `runtimes/registry.yaml` owns runtime metadata and capability labels.
- `references/contract/kernel.template.md` owns generated runtime kernels.
- `skills/*/SKILL.md`, `runtimes/*/kernel.md`, and OpenCode command wrappers are generated assets.
- Registry files must remain JSON-compatible YAML so tooling can use the Python standard library.

## Authoring Rules

- Prefer fewer concepts and shorter prompts.
- Keep skill prompts task-specific; do not restate global kernel rules unless the skill needs a concrete variant.
- Use `{{skill_support_path}}` and `{{runtime_reference_root}}` if template paths are needed.
- Keep `references/contract/` to `runtime.md`, `safety-tools.md`, `output.md`, and `kernel.template.md` unless a new file clearly removes more complexity than it adds.
- Do not add hooks, state-machine governance, mandatory status blocks, or subagent profiles without a specific approved plan.

## Key Paths

- `skills/` - skill sources and generated delivery assets
- `runtimes/` - runtime adapters and smoke lanes
- `references/contract/` - slim shared contract
- `tooling/generate/` - registry sync and renderers
- `tooling/install/` - shared installer core
- `tooling/validate/` - validation harness
- `tests/smoke/` - installer smoke tests

## Sync Rules

- Skill metadata: edit `skills/registry.yaml`, rerun `python3 tooling/generate/registry_sync.py`.
- Skill prompt: edit `skills/*/prompt.md`, rerun generation.
- Kernel behavior: edit `references/contract/kernel.template.md`, rerun generation.
- Contract behavior: edit `runtime.md`, `safety-tools.md`, or `output.md`.
- Runtime behavior: update `runtimes/registry.yaml`, affected adapter scripts/docs, and smoke tests together.

## Validation

Before merging runtime-facing changes:

1. Run `python3 tooling/generate/registry_sync.py` when generated surfaces are affected.
2. Run `scripts/validate-skills.sh`.
3. Run `scripts/validate-skills.sh --release` when install, runtime, wrapper, kernel delivery, or release-readiness behavior changed.
4. Confirm docs changed with public or maintainer surface changes.
5. Confirm shared content stayed runtime-neutral.

## Review Checklist

- Correct source layer, not generated asset?
- Shared content still runtime-neutral?
- Runtime-specific details under `runtimes/<name>/`?
- Generated assets synced?
- No new ceremony without clear payoff?
