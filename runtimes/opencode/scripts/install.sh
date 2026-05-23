# Sourced by install.sh — do not run directly.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  echo "error: this script is sourced by install.sh" >&2
  exit 1
fi

readonly OPENCODE_DIR="${B_AGENTIC_OPENCODE_DIR:-$HOME/.config/opencode}"
readonly METADATA_DIR="$OPENCODE_DIR/b-agentic"
readonly BACKUPS_DIR="$METADATA_DIR/backups"
readonly SKILLS_DST="${B_AGENTIC_SKILLS_DST:-$HOME/.claude/skills}"
readonly KERNEL_DST="$OPENCODE_DIR/AGENTS.md"
readonly KERNEL_SNAPSHOT_DST="$METADATA_DIR/AGENTS.md"
readonly REFERENCES_DST="$METADATA_DIR/references"
readonly TEMPLATES_DST="$METADATA_DIR/templates"
readonly MANIFEST_DST="$METADATA_DIR/install.json"

print_install_report() {
  local activation_state="$1" skill_count="$2" memory_action="$3" memory_backup="$4"

  log ""
  log "b-agentic OpenCode install complete"
  log "skillsSynced: $skill_count -> $SKILLS_DST"
  log "kernel: $memory_action -> $KERNEL_DST"
  log "references: sync -> $REFERENCES_DST"
  log "templates: sync -> $TEMPLATES_DST"
  log "manifest: write -> $MANIFEST_DST"
  log "backups:"
  log "  kernel: $memory_backup"
  log "activationState: $activation_state"
}

write_manifest() {
  local memory_action="$1" activation_state="$2" memory_backup="$3"
  shift 3
  local skills=("$@")

  if dry_run_enabled; then
    printf '[dry-run] write manifest %s\n' "$MANIFEST_DST" >&2
    return 0
  fi

  ensure_dir "$METADATA_DIR"
  env \
    MANIFEST_DST="$MANIFEST_DST" \
    TIMESTAMP="$TIMESTAMP" \
    RUNTIME="$RUNTIME" \
    MEMORY_ACTION="$memory_action" \
    ACTIVATION_STATE="$activation_state" \
    MEMORY_BACKUP="$memory_backup" \
    OPENCODE_DIR="$OPENCODE_DIR" \
    SKILLS_DST="$SKILLS_DST" \
    REFERENCES_DST="$REFERENCES_DST" \
    TEMPLATES_DST="$TEMPLATES_DST" \
    KERNEL_DST="$KERNEL_DST" \
    SKILLS="${skills[*]}" \
    python3 - <<'PY'
import json
import os
from pathlib import Path

skills = [name for name in os.environ['SKILLS'].split() if name]
manifest = {
    'suite': 'b-agentic',
    'runtime': os.environ['RUNTIME'],
    'installedAt': os.environ['TIMESTAMP'],
    'activationState': os.environ['ACTIVATION_STATE'],
    'memoryAction': os.environ['MEMORY_ACTION'],
    'paths': {
        'opencodeDir': os.environ['OPENCODE_DIR'],
        'kernel': os.environ['KERNEL_DST'],
        'skills': os.environ['SKILLS_DST'],
        'references': os.environ['REFERENCES_DST'],
        'templates': os.environ['TEMPLATES_DST'],
    },
    'skills': skills,
    'backups': {
        'agentsMd': os.environ['MEMORY_BACKUP'],
    },
}
Path(os.environ['MANIFEST_DST']).write_text(json.dumps(manifest, indent=2, sort_keys=True) + '\n')
PY
}

runtime_uninstall() {
  require_bin python3
  log "Uninstalling b-agentic from OpenCode personal config"
  local name
  if [ -f "$MANIFEST_DST" ]; then
    while IFS= read -r name; do
      [ -n "$name" ] || continue
      run_cmd rm -rf "$SKILLS_DST/$name"
    done < <(python3 - "$MANIFEST_DST" <<'PY'
import json
import sys
from pathlib import Path
path = Path(sys.argv[1])
try:
    data = json.loads(path.read_text())
except Exception:
    data = {}
for name in data.get('skills', []):
    print(name)
PY
)
  else
    for name in b-orchestrate b-plan b-research b-implement b-refactor b-debug b-test b-browser b-review b-audit b-ship; do
      run_cmd rm -rf "$SKILLS_DST/$name"
    done
  fi

  remove_managed_kernel
  run_cmd rm -rf "$METADATA_DIR"
  log "Uninstall complete. User-owned OpenCode files were preserved."
}

runtime_main() {
  command -v opencode >/dev/null 2>&1 || warn "opencode CLI not found; files will still be installed for OpenCode to discover later."

  local skill
  local installed_skills=()
  while IFS= read -r skill; do
    [ -n "$skill" ] || continue
    installed_skills+=("$skill")
  done < <(skill_names)
  install_skills

  install_references_and_templates

  local kernel_result memory_action activation_state memory_backup
  local -a kernel_lines
  kernel_result="$(install_kernel)"
  readarray -t kernel_lines <<< "$kernel_result"
  memory_action="${kernel_lines[0]:-preserve}"
  activation_state="${kernel_lines[1]:-pending}"
  memory_backup="${kernel_lines[2]:-none}"

  write_manifest "$memory_action" "$activation_state" "$memory_backup" "${installed_skills[@]}"

  print_install_report "$activation_state" "${#installed_skills[@]}" "$memory_action" "$memory_backup"
  ensure_repo_gitignore_guard
  if [ "$activation_state" = "pending" ]; then
    log "Existing $KERNEL_DST was preserved. Review $KERNEL_SNAPSHOT_DST and rerun with --replace-memory to activate the kernel."
    return 2
  fi
}
