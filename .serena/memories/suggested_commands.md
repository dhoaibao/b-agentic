# Suggested Commands

- `rtk git status --short` - check worktree when RTK is available.
- `rtk python3 tooling/generate/registry_sync.py` - sync generated skill/runtime/readme surfaces after changing registries, skill prompts, or kernel template.
- `rtk scripts/validate-skills.sh` - standard validation for skill/runtime-facing changes.
- `rtk scripts/validate-skills.sh --release` - release readiness validation for install/runtime/wrapper/kernel delivery changes.
- `rtk tests/smoke/install.sh` - installer smoke suite.
- `serena memories check` - sanity-check Serena memory references from project root.