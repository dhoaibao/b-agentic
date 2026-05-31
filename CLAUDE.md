# b-agentic - Maintainer Guide

Guidelines for editing and maintaining the `b-agentic` source repository. This file is repo maintainer guidance, not an installed runtime kernel.

## Scope

- `README.md` stays brief: repo overview, install, and high-level layout.
- Root `CLAUDE.md` is the shared maintainer guide for this repo, not a Claude-Code-only authoring spec.
- Claude Code is the reference runtime and primary native-first target; OpenCode, Codex CLI, Antigravity CLI, Cursor, and Zed are separate supported runtimes with their own install layouts.
- Shared runtime-facing content under `skills/` and `references/contract/` must stay runtime-neutral in behavior and path semantics.
- Runtime-specific paths, kernel filenames, install-layout details, wrappers, and caveats belong under `runtimes/<name>/`.
- Do not create a second root reference surface. Use root docs for orientation only, and keep detailed rules close to their owning sources.

## Source Of Truth

- `skills/registry.yaml` owns skill metadata and generated `SKILL.md` frontmatter.
- `skills/*/prompt.md` owns canonical skill bodies.
- `runtimes/registry.yaml` owns runtime metadata.
- `references/contract/kernel.template.md` owns the shared kernel source.
- `skills/*/SKILL.md` and `runtimes/*/kernel.md` are committed generated assets.
- Both registry files must stay in the JSON-compatible subset of YAML so repo tooling can use Python standard library only.
- Registry order is user-facing order for generated tables and wrappers unless a renderer explicitly narrows that surface.
- Do not hand-edit generated assets when a source file already owns the content.

## Shared Authoring Rules

- Shared prompts and shared contract prose must not hardcode runtime-specific behavior or paths.
- `{{skill_support_path}}` is the canonical token for skill-local support files in prompt sources.
- `{{runtime_reference_root}}` is the canonical token for the installed shared reference snapshot in prompt sources.
- In source prompts, reference skill-local support files with `{{skill_support_path}}/...` and shared contract/performance files with `{{runtime_reference_root}}/...`; the renderer maps them to runtime-local install paths in generated assets.
- When a skill depends on a contract section, add an explicit read gate at the step that uses it. Do not rely on passive reminders.
- Optional `skills/*/reference.md` files are support material, not a second root doc surface.
- In `skills/*/prompt.md`, references to `CLAUDE.md` mean the active runtime kernel, not this maintainer guide.

## Key Paths

- `skills/` - skill sources and generated delivery assets
- `runtimes/` - runtime adapters, configs, scripts, and smoke lanes
- `references/contract/` - detailed runtime contract
- `tooling/generate/` - renderers and doc generators
- `tooling/install/` - shared installer core
- `tooling/validate/` - shared validation harness
- `tests/smoke/` - shared smoke harness

## Skills

### Directory Shape

```text
skills/<name>/
├── prompt.md
├── SKILL.md
├── reference.md
├── examples.md
└── scripts/
```

- `prompt.md` is required and is the only canonical prompt source.
- `SKILL.md` is generated.
- `reference.md`, `examples.md`, and `scripts/` are optional. When `examples.md` is present, all Output blocks must mirror the Step contract (e.g., required literals enforced by `scripts/validate-skills.sh`).

### Generated Skill Asset Rules

- Generated `SKILL.md` files use the shared frontmatter contract from `skills/registry.yaml`; runtime-specific install paths are resolved by the renderer and installer, not by hand-authored prompt text.
- Frontmatter values live in `skills/registry.yaml`, not in generated files.
- Required fields: `name`, `description`.
- Common optional field: `argument-hint`.
- Only add runtime-sensitive optional fields such as `when_to_use`, `user-invocable`, `context`, `agent`, `paths`, or `shell` when there is a clear need.
- Do not add legacy compatibility metadata unless a plan explicitly requires it.

### Prompt Writing Rules

- Keep skill descriptions trigger-focused and short.
- Use imperative steps.
- Keep long schemas, rubrics, and edge-case protocols in `references/contract/`, not inside prompts.
- Add support files only when they materially improve token hygiene or reuse.

## Runtime Adapters

### Directory Shape

```text
runtimes/<name>/
├── kernel.md
├── configs/
├── scripts/
└── tests/
```

- Adapter directories own runtime-specific kernels, config templates, install hooks, wrappers, and caveats.
- For MCP launch commands that would otherwise use `npx`, prefer `pnpm dlx` when the package supports it so startup is faster.
- `install.sh` is the bootstrap entrypoint only; shared behavior lives in `tooling/install/common.sh`, and runtime-specific behavior lives in `runtimes/<name>/scripts/install.sh`.
- `scripts/validate-skills.sh` is a stable wrapper over the shared validation harness plus runtime validators, and `scripts/validate-skills.sh --release` adds installer smoke coverage for delivery-sensitive changes.
- `scripts/smoke-install.sh` is a stable wrapper over the shared smoke harness plus runtime smoke lanes.
- Use `runtimes/runtime-template/` as the starting point for a new adapter.
- Do not add a new runtime without updating generation, validation, smoke coverage, and docs in the same change.

## Sync Rules

- If skill metadata changes, edit `skills/registry.yaml`, rerun `python3 tooling/generate/registry_sync.py`, then update any hand-authored docs that describe the changed surface.
- If a skill prompt changes, edit `prompt.md`, rerender generated assets, and update support docs only when the public or maintainer surface changed.
- If kernel behavior changes, edit `references/contract/kernel.template.md`, rerender every affected `runtimes/*/kernel.md`, and keep docs aligned in the same change.
- If runtime metadata or adapter behavior changes, update `runtimes/registry.yaml` and the affected adapter docs/scripts together.
- Keep `README.md` overview-level; do not turn it into a second maintainer spec.

## Validation

Before merging runtime-facing changes:

1. Rerun `python3 tooling/generate/registry_sync.py` when generated surfaces are affected.
2. Run `scripts/validate-skills.sh`.
3. Run `scripts/validate-skills.sh --release` when install, runtime, wrapper, or kernel delivery behavior changed.
4. Run `scripts/smoke-install.sh` directly only when you need the smoke suite by itself while iterating.
5. Codex runtime install, validation, and smoke paths rely on Python 3.11+ standard-library `tomllib` support.
6. Antigravity CLI exposes `/b-*` through its native skill command loader from `~/.gemini/antigravity-cli/skills/`; keep MCP in `~/.gemini/antigravity-cli/mcp_config.json` and use `serverUrl` for remote MCP entries.
7. Check that shared content stayed runtime-neutral.
8. Check that docs changed in the same commit when the public or maintainer surface changed.
9. Check that prompt read gates point to `{{skill_support_path}}/...` for skill-local files and `{{runtime_reference_root}}/...` for shared references rather than hardcoded delivery paths.

## Review Checklist

- Is the change applied at the correct source layer rather than directly in a generated file?
- Does shared content stay runtime-neutral?
- Are runtime-specific install details kept under `runtimes/<name>/` rather than leaking into shared prompts or contract prose?
- Did the change preserve registry-driven generation and doc sync?
- Did the change avoid creating new root-level documentation sprawl?
