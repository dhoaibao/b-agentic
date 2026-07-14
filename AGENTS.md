<!-- b-init-managed:start -->
# b-agentic Maintainer Guide

## Repository Purpose

b-agentic is a slim workflow kernel for coding agents. It currently ships the Pi runtime; the registry-driven installer, runtime folder layout, and `runtimes/runtime-template/` scaffold keep it multi-runtime-ready so new runtimes can be added. Keep changes focused on routing, safety, evidence, verification, tool use, install reliability, and multi-runtime delivery.

The governing principle is: slim, strong, usable. Every workflow or prompt change needs a concrete failure mode or capability gap; do not add ceremony for hypothetical gains.

## Working Rules

- Treat `README.md` as the public overview and this file as maintainer guidance.
- Edit canonical sources, not generated outputs.
- Keep shared content under `skills/` and `references/` runtime-neutral.
- Put runtime-specific paths, templates, wrappers, caveats, and smoke tests under `runtimes/<name>/`.
- Preserve user-owned configuration in installers and adapters.
- Keep registry YAML JSON-compatible so the Python standard library can parse it.
- Keep skill prompts task-specific; do not duplicate global kernel rules unless a skill needs a concrete variant.
- Keep domain-specific workflows, issue-tracker conventions, team preferences, and product-specific skills out of core unless existing phases consume them as optional inputs.
- Do not add root documentation surfaces unless the task explicitly requires one.
- For behavior-shaping prompt changes, record the observed failure, intended behavior change, and a narrow regression check.

## Source of Truth

- `skills/registry.yaml` owns skill metadata and generated frontmatter.
- `skills/*/prompt.md` owns canonical skill bodies.
- `runtimes/registry.yaml` owns runtime metadata and capability labels.
- `references/kernel.template.md` owns the complete generated runtime kernel, including workflow, safety, tool-use, and shell conventions.
- `references/mcp_operations.yaml` owns managed MCP operation classifications; the kernel table is generated from it.
- `skills/*/SKILL.md`, `runtimes/*/kernel.md` are generated assets.

## Change Workflow

- Skill metadata: edit `skills/registry.yaml`.
- Skill behavior: edit the relevant `skills/*/prompt.md`.
- Kernel behavior: edit `references/kernel.template.md`.
- Managed MCP tool classes: edit `references/mcp_operations.yaml`, then run registry sync so the kernel table regenerates.
- Runtime behavior: update `runtimes/registry.yaml`, the affected adapter files, and smoke tests together.
- Use `{{skill_support_path}}` and `{{runtime_reference_root}}` for template paths where applicable.
- Keep `references/` limited to `kernel.template.md` and `mcp_operations.yaml` unless a new file clearly removes more complexity than it adds.
- After changing generated surfaces, run `python3 tooling/generate/registry_sync.py`.

Prefer fewer concepts and shorter prompts. Do not introduce hooks, state-machine governance, mandatory status blocks, or subagent profiles without an approved, evidence-backed need.

## Verification

Run the narrowest applicable checks:

```bash
python3 tooling/generate/registry_sync.py
scripts/validate-skills.sh
scripts/validate-skills.sh --release
scripts/b-agentic-audit.sh
```

For install or runtime-home validation after adapter changes, also use `scripts/smoke-install.sh`, `scripts/skill-doctor.sh --runtime=<name>`, and `scripts/mcp-doctor.sh --runtime=<name>`. For behavior-shaping prompt changes, compare like-for-like model settings with the opt-in `runtimes/pi/tests/prompt_effectiveness.py` runner; it makes external model calls and requires human scoring.

Use `--release` when install, runtime, wrapper, kernel delivery, or release-readiness behavior changes. Run `scripts/b-agentic-audit.sh` (also invoked by `b-review --audit-suite`) for self-audit checks: source/generated sync, kernel slimness, no developer-marker comments, runtime-template exclusion, and unresolved template tokens. Confirm generated assets are synchronized, shared content remains runtime-neutral, and public or maintainer docs reflect changed behavior.

## Codebase Map

- `skills/` — canonical prompts, registry metadata, and generated skill assets
- `runtimes/` — runtime adapters, configs, kernels, and smoke lanes
- `references/` — shared runtime kernel and MCP operation policy
- `tooling/generate/` — registry synchronization and renderers
- `tooling/install/` — shared installer implementation
- `tooling/validate/` — validation harness
- `tests/smoke/` — installer and runtime smoke coverage
- `scripts/` — validation, doctor, smoke, and acceptance entrypoints

## Review Before Handoff

- The change was made in the correct source layer.
- Generated outputs were refreshed when required.
- Shared content is runtime-neutral; runtime details stay under `runtimes/<name>/`.
- The change addresses a real problem without adding unnecessary process.
- Validation evidence matches the scope of the change.
<!-- b-init-managed:end -->
