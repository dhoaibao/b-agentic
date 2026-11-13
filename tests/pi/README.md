# Pi tests

Checks for the Pi runtime ([ADR-011](../../docs/decisions/ADR-011-pi-second-runtime.md)). Both
run from `scripts/validate-skills.sh`; neither needs credentials or a network.

| File | What it covers |
| --- | --- |
| `guard-cases.mjs` | Plain-Node cases for the guard core `pi/extensions/b-agentic/guard.mjs`: secret paths and `.b-agentic` writes blocked, fail-closed behavior, verify reminder, context queueing, subagent refusal when child gating fails. It also loads the extension entry `index.ts` with a fake `pi` and a temporary agent directory to check the child-gate registration: launches are refused when the pi-subagents module, its register function, or the permission-system entry is missing, and both extensions are required when present. Needs only `node` |
| `guard-probe.sh` | Runs the extension in real Pi with `stub-provider.ts`, an offline scripted model. Skipped when `pi` is absent. It retries a Pi start that stalls and fails after two attempts. The specialist-child case also needs `PI_PROBE_NPM_DIR` pointing at an agent directory's `npm` folder (for example `~/.pi/agent/npm`) with the pinned packages; without it that case is skipped |
| `stub-provider.ts` | The scripted model the probe uses |

The installer probe lives in `tests/install/pi-install-probe.sh` and runs under
`scripts/validate-skills.sh --release`. Its last case runs the installed extension in real Pi
and is skipped when Pi is absent or never starts.
