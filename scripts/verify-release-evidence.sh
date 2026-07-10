#!/usr/bin/env bash
# Verify operator release attestations plus static release gates.
# Does not re-run live interactive sessions.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec python3 "$ROOT_DIR/tooling/validate/release_evidence.py" "$@"
