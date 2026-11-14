#!/usr/bin/env bash
# Exercise claude/bin/b-state.mjs against throwaway git repositories.
# Needs only node, git, and jq: no network, credentials, or Claude Code.
# Exit contract: 0 done, 3 refused or not ok, 2 invalid input or state.
# shellcheck source-path=SCRIPTDIR
# shellcheck disable=SC2034 # cli and the other variables are used by the files this script sources.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
cli="$root/claude/bin/b-state.mjs"
work=$(mktemp -d)
trap 'chmod -R u+rwX "$work" 2>/dev/null; rm -rf "$work"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export GIT_CEILING_DIRECTORIES="$work"

# Sourced in order, in this shell: the sections share the work folder and the repository variables.
# shellcheck source=lib.sh
source "$root/tests/state/lib.sh"
# shellcheck source=cases/core.sh
source "$root/tests/state/cases/core.sh"
# shellcheck source=cases/commit-gates.sh
source "$root/tests/state/cases/commit-gates.sh"
# shellcheck source=cases/checks.sh
source "$root/tests/state/cases/checks.sh"
# shellcheck source=cases/commit-plan.sh
source "$root/tests/state/cases/commit-plan.sh"
# shellcheck source=cases/artifacts.sh
source "$root/tests/state/cases/artifacts.sh"
# shellcheck source=cases/steps.sh
source "$root/tests/state/cases/steps.sh"
# shellcheck source=cases/quick.sh
source "$root/tests/state/cases/quick.sh"
# shellcheck source=cases/worker.sh
source "$root/tests/state/cases/worker.sh"
# shellcheck source=cases/worktree.sh
source "$root/tests/state/cases/worktree.sh"
# shellcheck source=cases/owner.sh
source "$root/tests/state/cases/owner.sh"

echo "state probe passed"
