<!-- b-init-managed:start -->
# b-agentic Maintainer Guide

## Repository Purpose

b-agentic is a slim workflow kernel for the Pi coding agent. b-agentic and Pi are one product; keep changes focused on Pi workflows, safety, evidence, verification, tool use, and install reliability.

The governing principle is: slim, strong, usable. Every workflow or prompt change needs a concrete failure mode or capability gap; do not add ceremony for hypothetical gains.

## Working Rules

- Treat `README.md` as the public overview and this file as maintainer guidance.
- Edit canonical sources, not generated outputs.
- Keep shared content under `skills/` and `references/` focused on Pi.
- Put Pi integration paths, templates, extensions, and smoke tests under `pi/`.
- Preserve user-owned Pi configuration in installers.
- Keep the skill registry YAML JSON-compatible so the Python standard library can parse it.
- Keep skill prompts task-specific; do not duplicate global kernel rules unless a skill needs a concrete variant.
- Keep domain-specific workflows, issue-tracker conventions, team preferences, and product-specific skills out of core unless existing phases consume them as optional inputs.
- Do not add root documentation surfaces unless the task explicitly requires one.
- For behavior-shaping prompt changes, record the observed failure, intended behavior change, and a narrow regression check.

## Source of Truth

- `skills/registry.yaml` owns skill metadata and generated frontmatter.
- `skills/*/prompt.md` owns canonical skill bodies.
- `references/kernel.template.md` owns the complete generated Pi kernel, including workflow, safety, tool-use, and shell conventions.
- `references/mcp_operations.yaml` owns managed MCP operation classifications; the kernel table is generated from it.
- `skills/*/SKILL.md` are generated assets.

## Change Workflow

- Skill metadata: edit `skills/registry.yaml`.
- Skill behavior: edit the relevant `skills/*/prompt.md`.
- Kernel behavior: edit `references/kernel.template.md`.
- Managed MCP tool classes: edit `references/mcp_operations.yaml`, then run registry sync so the kernel table regenerates.
- Pi integration behavior: update the affected `pi/` files and smoke tests together.
- Use `{{skill_support_path}}` for template paths where applicable.
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

For install or Pi-home validation after integration changes, also use `scripts/smoke-install.sh`, `scripts/skill-doctor.sh`, and `scripts/mcp-doctor.sh`. For behavior-shaping prompt changes, compare like-for-like model settings with the opt-in `pi/tests/prompt_effectiveness.py` runner; it makes external model calls and requires human scoring.

Use `--release` when install, Pi integration, kernel delivery, or release-readiness behavior changes. Run `scripts/b-agentic-audit.sh` (also invoked by `b-review --audit-suite`) for self-audit checks: source/generated sync, kernel slimness, no developer-marker comments, and unresolved template tokens. Confirm generated assets are synchronized, Pi-specific code remains under `pi/`, and public or maintainer docs reflect changed behavior.

## Codebase Map

- `skills/` — canonical prompts, registry metadata, and generated skill assets
- `pi/` — Pi integration, configuration, extension, and smoke lanes
- `references/` — Pi kernel and MCP operation policy
- `tooling/generate/` — registry synchronization and renderers
- `tooling/install/` — shared installer implementation
- `tooling/validate/` — validation harness
- `tests/smoke/` — installer and Pi smoke coverage
- `scripts/` — validation, doctor, smoke, and acceptance entrypoints

## Review Before Handoff

- The change was made in the correct source layer.
- Generated outputs were refreshed when required.
- Pi-specific details stay under `pi/`.
- The change addresses a real problem without adding unnecessary process.
- Validation evidence matches the scope of the change.
<!-- b-init-managed:end -->
