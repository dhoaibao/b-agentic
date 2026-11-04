#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Run both checks so a traceability failure does not hide the structural result.
status=0
python3 "$ROOT_DIR/tooling/validate/decision_design.py" || status=$?
python3 "$ROOT_DIR/tooling/validate/suite_audit.py" "$@" || status=$?
exit "$status"
