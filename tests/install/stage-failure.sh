#!/usr/bin/env bash
# Fast unit test: a failed write inside a captured install stage must fail the
# stage and must not yield the success triplet that is later recorded as state.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/b-agentic-stage.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT

fail() { printf 'stage-failure.sh: %s\n' "$*" >&2; exit 1; }

# Run the body in a fresh shell so errexit state matches the real installer.
run_case() {
  local body="$1"
  # shellcheck disable=SC2016
  bash -c '
    set -euo pipefail
    ROOT_DIR="$1"; WORK_DIR="$2"
    step() { :; }
    die() { echo "die: $*" >&2; exit 1; }
    dry_run_enabled() { return 1; }
    run_cmd() { "$@"; }
    source "$ROOT_DIR/tooling/install/common.sh"
    path_confined_to_home() { return 0; }
    METADATA_DIR="$WORK_DIR/meta"; BACKUPS_DIR="$METADATA_DIR/backups"; TIMESTAMP=t
    KERNEL_SRC="$WORK_DIR/src-kernel.md"; printf kernel >"$KERNEL_SRC"
    KERNEL_DST="$WORK_DIR/dst/kernel.md"
    KERNEL_SNAPSHOT_DST="$METADATA_DIR/snapshot.md"
    mkdir -p "$WORK_DIR/dst" "$METADATA_DIR"
    INSTALL_STAGE_CURRENT=0
    '"$body" bash "$ROOT_DIR" "$WORK_DIR"
}

# 1. A failing copy stage must abort with nonzero status and no success triplet.
# shellcheck disable=SC2016  # bodies are intentionally literal child-shell code
out="$(run_case '
  cp() { return 1; }
  run_install_triplet_stage "Syncing kernel" install_kernel preserve pending none ACTION STATE BACKUP
  echo "REACHED: $ACTION $STATE"
' 2>&1)" && fail "failed copy stage exited 0: $out"
case "$out" in *REACHED*) fail "success state recorded after failed copy: $out" ;; esac

# 2. Caller errexit state is restored and a succeeding stage still reports its triplet.
# shellcheck disable=SC2016  # bodies are intentionally literal child-shell code
out="$(run_case '
  run_install_triplet_stage "Syncing kernel" install_kernel preserve pending none ACTION STATE BACKUP
  case "$-" in *e*) ;; *) echo "errexit-lost" ;; esac
  echo "RESULT: $ACTION $STATE $BACKUP"
' 2>&1)" || fail "healthy stage failed: $out"
case "$out" in *"RESULT: write active none"*) ;; *) fail "unexpected triplet: $out" ;; esac
case "$out" in *errexit-lost*) fail "caller errexit not restored" ;; esac

# 3. A failed kernel backup must not be followed by a replacement.
# shellcheck disable=SC2016  # bodies are intentionally literal child-shell code
out="$(run_case '
  printf user >"$KERNEL_DST"; printf stale >"$KERNEL_SNAPSHOT_DST"
  replace_memory_enabled() { return 0; }
  cp() { return 1; }
  run_install_triplet_stage "Syncing kernel" install_kernel preserve pending none ACTION STATE BACKUP
  echo "REACHED"
' 2>&1)" && fail "failed backup stage exited 0: $out"
case "$out" in *REACHED*) fail "install continued after failed backup" ;; esac
[ "$(cat "$WORK_DIR/dst/kernel.md")" = user ] || fail "user kernel changed after failed backup"

# 4. Backup-only failure (replacement copies would succeed) must not replace the
# user kernel, with the capability present and when inherit_errexit is unavailable.
for variant in present unavailable; do
  # shellcheck disable=SC2016  # bodies are intentionally literal child-shell code
  out="$(run_case '
    printf user >"$KERNEL_DST"; printf stale >"$KERNEL_SNAPSHOT_DST"
    replace_memory_enabled() { return 0; }
    cp() { case "$2" in "$BACKUPS_DIR"/*) return 23 ;; *) command cp "$@" ;; esac; }
    if [ "'"$variant"'" = unavailable ]; then
      shopt() { return 1; }
    fi
    run_install_triplet_stage "Syncing kernel" install_kernel preserve pending none ACTION STATE BACKUP
    echo "REACHED: $ACTION $STATE $BACKUP"
  ' 2>&1)" && fail "backup-only failure ($variant) exited 0: $out"
  case "$out" in *REACHED*) fail "success state after backup-only failure ($variant): $out" ;; esac
  [ "$(cat "$WORK_DIR/dst/kernel.md")" = user ] || fail "user kernel replaced after failed backup ($variant)"
done

printf 'install stage failure propagation passed\n'
