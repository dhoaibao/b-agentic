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

python3 "$ROOT_DIR/tooling/validate/shared.py"
python3 "$ROOT_DIR/tooling/validate/behavior.py"
python3 "$ROOT_DIR/tooling/validate/mcp_policy.py"
bash "$ROOT_DIR/pi/scripts/validate.sh"

if [ "$run_release" -eq 1 ]; then
	bash "$ROOT_DIR/tests/smoke/install.sh"
fi
