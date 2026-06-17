# Conventions

- Keep product slim: add only concepts improving routing, safety, evidence, verification, tool use, install reliability, or multi-runtime delivery.
- Do not add root-level documentation surfaces beyond existing `README.md` and `AGENTS.md`.
- Shared runtime-facing content under `skills/` and `references/contract/` must remain runtime-neutral.
- Runtime-specific paths, templates, wrappers, caveats, and smoke tests belong under `runtimes/<name>/`.
- Edit source-of-truth files, not generated assets: skill metadata in `skills/registry.yaml`; skill bodies in `skills/*/prompt.md`; kernel behavior in `references/contract/kernel.template.md`; runtime metadata in `runtimes/registry.yaml`.
- Avoid hooks, state-machine governance, mandatory status blocks, or subagent profiles without an approved plan.
