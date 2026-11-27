#!/usr/bin/env bash
# Exercise claude/bin/b-state.mjs against throwaway git repositories.
# Needs only bun, git, and jq: no network, credentials, or Claude Code.
# Exit contract: 0 done, 3 refused or not ok, 2 invalid input or state.
#
# Each file in cases/ is an independent shard with its own work folder and repositories
# (shared helpers live in lib.sh). With no argument every shard runs at the same time and a
# failed shard's log is printed; `state-probe.sh <case>` runs one shard in the foreground.
# shellcheck source-path=SCRIPTDIR
# shellcheck disable=SC2034 # cli and the other variables are used by the files this script sources.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
cases=(core commit-gates checks commit-plan artifacts steps quick worker worktree owner pi stats budget)

if [ "$#" -eq 0 ]; then
  logs=$(mktemp -d)
  trap 'rm -rf "$logs"' EXIT
  pids=()
  for name in "${cases[@]}"; do
    bash "${BASH_SOURCE[0]}" "$name" >"$logs/$name.log" 2>&1 &
    pids+=($!)
  done
  failed=()
  for index in "${!cases[@]}"; do
    wait "${pids[$index]}" || failed+=("${cases[$index]}")
  done
  if [ "${#failed[@]}" -gt 0 ]; then
    for name in "${failed[@]}"; do
      echo "--- state probe shard failed: $name" >&2
      cat "$logs/$name.log" >&2
    done
    echo "state probe failed: ${failed[*]}" >&2
    exit 1
  fi
  echo "state probe passed"
  exit 0
fi

name=$1
found=0
for known in "${cases[@]}"; do [ "$known" != "$name" ] || found=1; done
[ "$found" -eq 1 ] || { echo "usage: state-probe.sh [${cases[*]}]" >&2; exit 2; }

cli="$root/claude/bin/b-state.mjs"
# The runtime that runs the CLI under test: bun with the hardening flags the installer writes (ADR-018), or
# node (STATE_PROBE_RUNTIME=node), which the CLIs stay runnable under and which the Pi wrappers run them with.
js=(bun --no-env-file --config=/dev/null)
if [ "${STATE_PROBE_RUNTIME:-}" = node ]; then js=(node); fi
work=$(mktemp -d)
trap 'chmod -R u+rwX "$work" 2>/dev/null; rm -rf "$work"' EXIT
# A finished run appends to the run-stats store under the install home (ADR-035): HOME is a throwaway
# folder with no install home, so no probe writes to the real one.
export HOME="$work/home"
mkdir -p "$HOME"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export GIT_CEILING_DIRECTORIES="$work"

# shellcheck source=lib.sh
source "$root/tests/state/lib.sh"
# shellcheck source=cases/core.sh
source "$root/tests/state/cases/$name.sh"

echo "state probe passed: $name"
