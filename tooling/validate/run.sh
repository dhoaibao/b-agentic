#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"

run_release=0
while [ $# -gt 0 ]; do
	case "$1" in
	--release) run_release=1 ;;
	*)
		printf 'usage: %s [--release]\n' "${BASH_SOURCE[0]}" >&2
		exit 2
		;;
	esac
	shift
done

python3 "$ROOT_DIR/tooling/generate/registry_sync.py" --self-test --check
python3 "$ROOT_DIR/tooling/validate/capabilities.py" --self-test
python3 "$ROOT_DIR/tooling/validate/changelog.py"
python3 "$ROOT_DIR/tooling/validate/shared.py"
python3 "$ROOT_DIR/tooling/validate/behavior.py"
python3 "$ROOT_DIR/tooling/validate/mcp_policy.py"
python3 "$ROOT_DIR/tooling/validate/mcp_probe.py" --self-test
python3 "$ROOT_DIR/tooling/validate/session_readiness.py" --self-test
python3 "$ROOT_DIR/tests/prompt_effectiveness.py" --validate-inputs
python3 "$ROOT_DIR/tests/prompt_effectiveness.py" --routing --validate-inputs
python3 "$ROOT_DIR/tests/prompt_effectiveness.py" --fixtures "$ROOT_DIR/tests/behavior/research.json" --skill "$ROOT_DIR/skills/b-research/SKILL.md" --validate-inputs
python3 "$ROOT_DIR/tests/prompt_effectiveness.py" --fixtures "$ROOT_DIR/tests/behavior/test-selection.json" --skill "$ROOT_DIR/skills/b-test/SKILL.md" --validate-inputs
python3 "$ROOT_DIR/tests/prompt_effectiveness.py" --fixtures "$ROOT_DIR/tests/behavior/browser-evidence.json" --skill "$ROOT_DIR/skills/b-browser/SKILL.md" --validate-inputs
python3 "$ROOT_DIR/tests/prompt_effectiveness.py" --fixtures "$ROOT_DIR/tests/behavior/ui-guidance.json" --skill "$ROOT_DIR/skills/b-design/SKILL.md" --validate-inputs
python3 "$ROOT_DIR/tests/prompt_effectiveness.py" --fixtures "$ROOT_DIR/tests/behavior/init-guidance.json" --skill "$ROOT_DIR/skills/b-init/SKILL.md" --validate-inputs
python3 "$ROOT_DIR/tooling/validate/browser_evidence.py" --self-test
python3 "$ROOT_DIR/skills/b-diagram/diagram.py" self-test
bash "$ROOT_DIR/adapters/pi/scripts/validate.sh"

if [ "$run_release" -eq 1 ]; then
	if command -v rtk >/dev/null 2>&1; then
		python3 "$ROOT_DIR/tooling/validate/session_readiness.py"
	else
		printf '%s\n' 'RTK policy compatibility skipped: rtk is not installed.'
	fi
	bash "$ROOT_DIR/tests/smoke/install.sh"
fi
