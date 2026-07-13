# Runtime Adapter Scaffold

This scaffold documents the minimum adapter-owned files a new runtime should provide.

It is intentionally not listed in `runtimes/registry.yaml`, so validation, smoke coverage, rendering, and install flows ignore it until a real runtime is added.

## How to use it

1. Copy `runtimes/runtime-template/` to `runtimes/<name>/`.
2. Add the new runtime entry to `runtimes/registry.yaml`.
3. Rerun `python3 tooling/generate/registry_sync.py` so `runtimes/<name>/kernel.md` renders from `references/kernel.template.md`.
4. Replace every placeholder in `configs/README.md`, `scripts/install.sh`, `scripts/validate.sh`, and `tests/smoke.sh`.
5. Update `README.md`, `AGENTS.md`, and any adapter-specific docs in the same change.
6. Run `scripts/validate-skills.sh` and `scripts/smoke-install.sh`.

## Examples

Annotated examples from existing adapters live in `examples/`. Add a new example there when a runtime introduces a non-trivial config-merge pattern (for example, preserving user-owned config while injecting managed MCP servers), and document it in this list.

## Required adapter-owned surfaces

- `configs/README.md` documents runtime layout, config shape, and adapter caveats.
- `scripts/install.sh` is the thin runtime driver sourced by `install.sh`.
- `scripts/validate.sh` checks adapter-only invariants.
- `tests/smoke.sh` registers the runtime's smoke lane for `tests/smoke/install.sh`.

The root wrappers stay stable. Adding a runtime should not require editing `scripts/validate-skills.sh`, `scripts/smoke-install.sh`, or the shared installer architecture.

## Sibling-layout constraint

When registering a new runtime in `runtimes/registry.yaml`, `skills_install_root` and `metadata_root` must share a common parent directory, and `metadata_root` must be named `b-agentic`:

```
<parent>/skills/     ← skills_install_root
<parent>/b-agentic/  ← metadata_root
```

The renderer hardcodes `RENDERED_RUNTIME_REFERENCE_ROOT = "../../b-agentic/references"` into every generated `SKILL.md`. A `SKILL.md` installed at `skills_install_root/<skill>/SKILL.md` resolves that path to `<parent>/b-agentic/references`. If `skills_install_root` and `metadata_root` do not share a parent — or if `metadata_root` is not named `b-agentic` — every read-gate in every installed skill will point to a non-existent path at runtime. The shared validator enforces this invariant.

## Adapter-owned config schema

`config_schema_family` is an adapter-defined non-empty identifier, not a shared
allowlist. The adapter's validator and readiness tooling own the semantics of
that schema. An adapter declaring `support_tier: operation-enforced` must ship
`runtimes/<name>/scripts/validate_mcp_policy.py`, accepting `--policy <path>`
and exiting nonzero when its runtime enforcement disagrees with the canonical
policy. Shared validation discovers and runs that adapter-owned validator; it
fails closed when the script is absent.
