# Task Completion

- For runtime-facing generated surface changes: run `rtk python3 tooling/generate/registry_sync.py`.
- Standard validation before merging runtime-facing changes: run `rtk scripts/validate-skills.sh`.
- For install, runtime, wrapper, kernel delivery, or release-readiness behavior: run `rtk scripts/validate-skills.sh --release`.
- Installer-specific changes should include `rtk tests/smoke/install.sh` when feasible.
- Confirm docs changed when public or maintainer surfaces change.
- Confirm shared content remains runtime-neutral.