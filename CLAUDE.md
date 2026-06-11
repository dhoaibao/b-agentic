# b-agentic - Maintainer Guide

> This is the maintainer guide for the b-agentic source repository. For the public overview, install instructions, and user-facing documentation, see `README.md`.

This file is maintainer guidance for editing the repository itself. It is not the repository overview and it is not an installed runtime kernel.

## Product Direction

`b-agentic` is a workflow harness, not just a skill suite. Its job is to give AI agents a small, reliable operating system for developer work: route by intent, apply safety gates, ground claims in evidence, verify before claiming completion, and hand off between phases without losing context.

The product vision is multi-runtime support. Claude Code is the reference runtime, but shared behavior must remain portable across OpenCode, Codex CLI, and Kilo Code through runtime adapters.

The guiding standard is: slim, strong, usable. Prefer fewer concepts, clearer contracts, and validation that protects real behavior. Remove layers that only make agents carry more ceremony; keep tooling that improves correctness, install reliability, or cross-runtime delivery.

## Scope

- `README.md` is the repository overview. Keep it brief: product summary, install, supported runtimes, skills, layout, validation, and links to deeper docs.
- `CLAUDE.md` is the maintainer guide. Keep source-of-truth, authoring, sync, validation, and review guidance here.
- Root `CLAUDE.md` is shared repo guidance, not a Claude-Code-only authoring spec.
- Claude Code is the reference runtime; OpenCode, Codex CLI, and Kilo Code are supported through runtime adapters.
- Shared runtime-facing content under `skills/` and `references/contract/` must stay runtime-neutral.
- Runtime-specific paths, kernel filenames, install layout, wrappers, and caveats belong under `runtimes/<name>/`.
- Do not create a second root reference surface.

## Source Of Truth

- `skills/registry.yaml` owns skill metadata and generated `SKILL.md` frontmatter.
- `skills/*/prompt.md` owns canonical skill bodies.
- `runtimes/registry.yaml` owns runtime metadata.
- `runtimes/registry.yaml` also owns runtime-native capability support and adoption intent. Claude Code is the capability ceiling: shared intent may depend on a capability only when the Claude Code entry marks it `adoption: "shared"`.
- `references/contract/kernel.template.md` owns the shared kernel source.
- `skills/*/SKILL.md` and `runtimes/*/kernel.md` are committed generated assets.
- Registry files must stay in the JSON-compatible YAML subset so repo tooling can use Python standard library only.
- Registry order is user-facing unless a renderer explicitly narrows it.
- Do not hand-edit generated assets when a source file owns the content.

## Authoring Rules

- Shared prompts and contract prose must not hardcode runtime-specific behavior or paths. Exception: `$ARGUMENTS` is the shared argument injection token used in skill prompts — each runtime adapter resolves it natively when a skill is invoked with arguments; treat unresolved `$ARGUMENTS` as "no arguments provided."
- Use `{{skill_support_path}}` for skill-local support files and `{{runtime_reference_root}}` for installed shared references.
- Add explicit read gates at the step that uses a contract section.
- Keep shared schemas, rubrics, and edge-case protocols in the few `references/contract/` files, not prompts.
- Keep `references/contract/` slim: `runtime.md`, `safety-tools.md`, `output.md`, `decisions.md`, `index.md`, and `kernel.template.md`.
- Optional `skills/*/reference.md`, `examples.md`, and `scripts/` are support material, not a second root doc surface.
- In `skills/*/prompt.md`, `CLAUDE.md` means the active runtime kernel, not this maintainer guide.

## Key Paths

- `skills/` - skill sources and generated delivery assets
- `runtimes/` - runtime adapters, configs, scripts, and smoke lanes
- `references/contract/` - slim runtime contract
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

Runtime-native assets such as permissions, hooks, rules, subagents, plugins, wrappers, and custom tools must be declared in `runtimes/registry.yaml`. Adapter-only capabilities may improve one runtime, but shared prompts and contracts must not require them unless Claude Code has `adoption: "shared"` for the same capability. Subagent profiles are deferred extras, not default install surface; do not make them part of the shared workflow contract without explicit adoption and validation.

Do not add a runtime without updating generation, validation, smoke coverage, and docs in the same change.

## Sync Rules

- Skill metadata: edit `skills/registry.yaml`, rerun `python3 tooling/generate/registry_sync.py`, then update hand-authored docs if the public surface changed.
- Skill prompt: edit `skills/*/prompt.md`, rerender generated assets, and update support docs only when needed.
- Kernel behavior: edit `references/contract/kernel.template.md`, rerender affected `runtimes/*/kernel.md`, and keep docs aligned.
- Contract behavior: edit one of `runtime.md`, `safety-tools.md`, `output.md`, or `decisions.md`; do not add a new contract file unless the four-file runtime surface is demonstrably insufficient.
- Runtime behavior: update `runtimes/registry.yaml` and affected adapter docs/scripts together. If runtime-native capabilities change, update the generated README capability table and validate the Claude-first adoption gate.
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
8. Confirm shared content stayed runtime-neutral and docs changed with public or maintainer surface changes.
9. Confirm prompt read gates use `{{skill_support_path}}/...` or `{{runtime_reference_root}}/...`, not hardcoded delivery paths.

## Review Checklist

- Correct source layer, not generated asset?
- Shared content still runtime-neutral?
- Runtime-specific details under `runtimes/<name>/`?
- Registry-driven generation and docs still synced?
- No new root-level documentation sprawl?

## Development Hygiene

Keep local runtime state out of the source tree. The installer writes to user-scope paths (`~/.claude/`, `~/.config/opencode/`, `~/.codex/`). Do not install runtimes into the repo root during development; `.gitignore` covers common local directories, but the cleanest setup is to let the installer use its default paths.
