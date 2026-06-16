# Sourced by install.sh — do not run directly.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  echo "error: this script is sourced by install.sh" >&2
  exit 1
fi

readonly RUNTIME_UNINSTALL_LABEL="Codex CLI personal config"
readonly RUNTIME_PRESERVE_LABEL="Codex CLI"
readonly CODEX_DIR="${B_AGENTIC_CODEX_DIR:-$HOME/.codex}"
readonly METADATA_DIR="$CODEX_DIR/b-agentic"
readonly BACKUPS_DIR="$METADATA_DIR/backups"
readonly SKILLS_DST="${B_AGENTIC_SKILLS_DST:-$HOME/.codex/skills}"
readonly RULES_SRC="$SOURCE_DIR/runtimes/$RUNTIME/rules"
readonly RULES_DST="${B_AGENTIC_CODEX_RULES_DIR:-$HOME/.codex/rules}"
readonly RULES_SNAPSHOT_DST="$METADATA_DIR/rules"
readonly KERNEL_DST="$CODEX_DIR/AGENTS.md"
readonly KERNEL_SNAPSHOT_DST="$METADATA_DIR/AGENTS.md"
readonly REFERENCES_DST="$METADATA_DIR/references"
readonly TEMPLATES_DST="$METADATA_DIR/templates"
readonly MANIFEST_DST="$METADATA_DIR/install.json"
readonly CODEX_CONFIG_DST="${B_AGENTIC_CODEX_CONFIG:-$HOME/.codex/config.toml}"
readonly CODEX_CONFIG_BACKUP_KEY="codexConfig"

readonly CODEX_MANAGED_BEGIN="# BEGIN b-agentic managed config"
readonly CODEX_MANAGED_END="# END b-agentic managed config"

CONTEXT7_API_KEY_INPUT=""
BRAVE_API_KEY_INPUT=""
FIRECRAWL_API_KEY_INPUT=""
FIRECRAWL_API_URL_INPUT=""

runtime_require_tomllib() {
  python3 - <<'PY' >/dev/null 2>&1 || die "Codex CLI install requires Python 3.11+ (stdlib tomllib)."
import tomllib
PY
}

codex_secret_configured() {
  local server="$1" section="$2" key="$3"
  [ -f "$CODEX_CONFIG_DST" ] || return 1
  python3 - "$CODEX_CONFIG_DST" "$server" "$section" "$key" <<'PY'
import sys
from pathlib import Path

try:
    import tomllib
except ModuleNotFoundError:
    sys.exit(1)

path = Path(sys.argv[1])
server, section, key = sys.argv[2:5]
try:
    data = tomllib.loads(path.read_text())
except Exception:
    sys.exit(1)

value = data.get('mcp_servers', {}).get(server, {}).get(section, {}).get(key)
sys.exit(0 if isinstance(value, str) and value else 1)
PY
}

runtime_mcp_key_configured() {
  codex_secret_configured "$@"
}

runtime_warn_missing_cli() {
  command -v codegraph >/dev/null 2>&1 || warn "codegraph CLI not found; CodeGraph MCP will not start until CodeGraph is installed."
}

runtime_upgrade_cli() {
  if command -v codex >/dev/null 2>&1; then
    log "Codex CLI already installed; updating"
    if run_cmd codex update; then
      log "Codex CLI updated"
    else
      warn "Codex CLI update failed; continuing with existing CLI"
    fi
    return 0
  fi

  log "Codex CLI not found; installing"
  if dry_run_enabled; then
    printf '[dry-run] curl -fsSL https://chatgpt.com/codex/install.sh | sh\n' >&2
  elif curl -fsSL https://chatgpt.com/codex/install.sh | sh; then
    log "Codex CLI installed"
  else
    warn "Codex CLI install failed; files will still be installed for Codex to discover later"
  fi
}

runtime_install_config_stage_count() {
  printf '1'
}

collect_codex_api_keys() {
  can_prompt_api_keys || return 0

  printf '\nOptional MCP API keys. Values are written to %s and never to tracked templates.\n' "$CODEX_CONFIG_DST" > /dev/tty
  if ! codex_secret_configured context7 http_headers CONTEXT7_API_KEY; then
    CONTEXT7_API_KEY_INPUT="$(prompt_secret 'Context7 API key')"
  fi
  if ! codex_secret_configured brave-search env BRAVE_API_KEY; then
    BRAVE_API_KEY_INPUT="$(prompt_secret 'Brave Search API key')"
  fi
  if ! codex_secret_configured firecrawl env FIRECRAWL_API_KEY; then
    FIRECRAWL_API_KEY_INPUT="$(prompt_secret 'Firecrawl API key')"
  fi
  if ! codex_secret_configured firecrawl env FIRECRAWL_API_URL; then
    FIRECRAWL_API_URL_INPUT="$(prompt_value 'Firecrawl API URL' 'leave blank to use current default')"
  fi
}

install_codex_config() {
  local existed action backup="none"
  existed=0
  action="write"
  if [ -e "$CODEX_CONFIG_DST" ]; then
    existed=1
    action="merge"
  fi

  if dry_run_enabled; then
    printf '[dry-run] manage Codex config %s\n' "$CODEX_CONFIG_DST" >&2
    printf '%s\nactive\n%s' "$action" "$(manifest_backup_value "$CODEX_CONFIG_BACKUP_KEY" none)"
    return 0
  fi

  ensure_dir "$(dirname "$CODEX_CONFIG_DST")"

  local tmp rc
  tmp="$(mktemp "${TMPDIR:-/tmp}/b-agentic-codex-config.XXXXXX")"
  if env \
    CODEX_CONFIG_DST="$CODEX_CONFIG_DST" \
    CODEX_MANAGED_BEGIN="$CODEX_MANAGED_BEGIN" \
    CODEX_MANAGED_END="$CODEX_MANAGED_END" \
    SKILLS_DST="$SKILLS_DST" \
    SKILLS="${INSTALL_SKILL_NAMES[*]}" \
    JSON_TMP="$tmp" \
    CONTEXT7_API_KEY_INPUT="$CONTEXT7_API_KEY_INPUT" \
    BRAVE_API_KEY_INPUT="$BRAVE_API_KEY_INPUT" \
    FIRECRAWL_API_KEY_INPUT="$FIRECRAWL_API_KEY_INPUT" \
    FIRECRAWL_API_URL_INPUT="$FIRECRAWL_API_URL_INPUT" \
    SOURCE_DIR="$SOURCE_DIR" \
    python3 - <<'PY'
import json
import os
import tomllib
from pathlib import Path


def load_toml(text: str, label: str):
    if not text.strip():
        return {}
    try:
        return tomllib.loads(text)
    except tomllib.TOMLDecodeError as exc:
        raise SystemExit(f"invalid Codex config {label}: {exc}")


def split_managed_block(text: str, begin: str, end: str) -> tuple[str, str]:
    if begin not in text:
        return text, ""
    if end not in text:
        raise SystemExit("invalid Codex config: missing managed block terminator")
    prefix, remainder = text.split(begin, 1)
    managed_body, suffix = remainder.split(end, 1)
    return prefix + suffix, begin + managed_body + end


def toml_string(value: str) -> str:
    return json.dumps(value)


path = Path(os.environ["CODEX_CONFIG_DST"])
begin = os.environ["CODEX_MANAGED_BEGIN"]
end = os.environ["CODEX_MANAGED_END"]
skills_root = Path(os.environ["SKILLS_DST"])
source_dir = Path(os.environ["SOURCE_DIR"])
template_path = source_dir / "runtimes" / "codex-cli" / "configs" / "mcp.user.template.toml"
skills = [name for name in os.environ.get("SKILLS", "").split() if name]
current_text = path.read_text() if path.exists() else ""
base_text, _managed_text = split_managed_block(current_text, begin, end)

current = load_toml(current_text, "current file")
base = load_toml(base_text, "user-owned portion")
template = load_toml(template_path.read_text(), "Codex MCP template")
template_servers = template.get("mcp_servers")
if not isinstance(template_servers, dict):
    raise SystemExit("invalid Codex MCP template: missing mcp_servers table")
package_overrides = {
    "brave-search": os.environ.get("B_AGENTIC_BRAVE_MCP_PACKAGE", "@brave/brave-search-mcp-server"),
    "firecrawl": os.environ.get("B_AGENTIC_FIRECRAWL_MCP_PACKAGE", "firecrawl-mcp"),
    "playwright": os.environ.get("B_AGENTIC_PLAYWRIGHT_MCP_PACKAGE", "@playwright/mcp@latest"),
}

current_servers = current.get("mcp_servers") if isinstance(current.get("mcp_servers"), dict) else {}
base_servers = base.get("mcp_servers") if isinstance(base.get("mcp_servers"), dict) else {}
base_skill_configs = base.get("skills", {}).get("config", [])
if not isinstance(base_skill_configs, list):
    raise SystemExit("invalid Codex config: skills.config must be an array when present")

existing_skill_paths = set()
for entry in base_skill_configs:
    if isinstance(entry, dict):
        skill_path = entry.get("path")
        if isinstance(skill_path, str) and skill_path:
            existing_skill_paths.add(skill_path)


def current_literal(server_name: str, section: str, key: str) -> str | None:
    server = current_servers.get(server_name)
    if not isinstance(server, dict):
        return None
    nested = server.get(section)
    if not isinstance(nested, dict):
        return None
    value = nested.get(key)
    return value if isinstance(value, str) and value else None


def toml_value(value) -> str:
    if isinstance(value, str):
        return toml_string(value)
    if isinstance(value, list) and all(isinstance(item, str) for item in value):
        return "[" + ", ".join(toml_string(item) for item in value) + "]"
    if isinstance(value, dict) and all(isinstance(key, str) and isinstance(item, str) for key, item in value.items()):
        return "{ " + ", ".join(f"{key} = {toml_string(item)}" for key, item in value.items()) + " }"
    raise SystemExit(f"unsupported Codex MCP template value: {value!r}")


def rendered_server(name: str, server: dict) -> dict:
    rendered = dict(server)
    package_override = package_overrides.get(name)
    args = rendered.get("args")
    if package_override and isinstance(args, list) and len(args) >= 2 and args[0] == "dlx":
        rendered["args"] = [args[0], package_override, *args[2:]]
    if name == "context7":
        if context7_key:
            rendered.pop("env_http_headers", None)
            rendered["http_headers"] = {"CONTEXT7_API_KEY": context7_key}
    elif name == "brave-search":
        if brave_key:
            rendered.pop("env_vars", None)
            rendered["env"] = {"BRAVE_API_KEY": brave_key}
    elif name == "firecrawl":
        if firecrawl_key:
            rendered.pop("env_vars", None)
            env = {"FIRECRAWL_API_KEY": firecrawl_key}
            if firecrawl_url:
                env["FIRECRAWL_API_URL"] = firecrawl_url
            rendered["env"] = env
        elif firecrawl_url:
            rendered["env"] = {"FIRECRAWL_API_URL": firecrawl_url}
    return rendered


def add_template_server(name: str, server: dict):
    if name in base_servers:
        return
    if not isinstance(server, dict):
        raise SystemExit(f"invalid Codex MCP template server {name!r}: expected table")
    lines.append(f"[mcp_servers.{name}]")
    for key, value in rendered_server(name, server).items():
        lines.append(f"{key} = {toml_value(value)}")
    lines.append("")


context7_key = os.environ.get("CONTEXT7_API_KEY_INPUT") or current_literal("context7", "http_headers", "CONTEXT7_API_KEY")
brave_key = os.environ.get("BRAVE_API_KEY_INPUT") or current_literal("brave-search", "env", "BRAVE_API_KEY")
firecrawl_key = os.environ.get("FIRECRAWL_API_KEY_INPUT") or current_literal("firecrawl", "env", "FIRECRAWL_API_KEY")
firecrawl_url = os.environ.get("FIRECRAWL_API_URL_INPUT") or current_literal("firecrawl", "env", "FIRECRAWL_API_URL")
lines = [
    begin,
    "# Managed by b-agentic for Codex CLI.",
    "# Remove by rerunning install.sh --runtime=codex-cli --uninstall.",
    "",
]

for server_name, server_body in template_servers.items():
    add_template_server(server_name, server_body)

for name in skills:
    skill_path = str(skills_root / name)
    if skill_path in existing_skill_paths:
        continue
    lines.extend([
        "[[skills.config]]",
        f"path = {toml_string(skill_path)}",
        "enabled = true",
        "",
    ])

while lines and lines[-1] == "":
    lines.pop()
lines.append(end)

managed_block = "\n".join(lines)
base_stripped = base_text.strip()
final_text = managed_block if not base_stripped else base_stripped + "\n\n" + managed_block
final_text += "\n"

if load_toml(final_text, "rendered output") is None:
    raise SystemExit("invalid rendered Codex config")

if final_text == current_text:
    raise SystemExit(2)

Path(os.environ["JSON_TMP"]).write_text(final_text)
PY
  then
    rc=0
  else
    rc=$?
  fi

  if [ "$rc" -eq 2 ]; then
    rm -f "$tmp"
    printf '%s\nactive\n%s' "$action" "$(manifest_backup_value "$CODEX_CONFIG_BACKUP_KEY" none)"
    return 0
  fi
  if [ "$rc" -ne 0 ]; then
    rm -f "$tmp"
    die "failed to write Codex config: $CODEX_CONFIG_DST"
  fi

  if [ "$existed" -eq 1 ]; then
    backup="$(backup_file "$CODEX_CONFIG_DST")"
  fi
  run_cmd mv "$tmp" "$CODEX_CONFIG_DST"
  printf '%s\nactive\n%s' "$action" "${backup:-none}"
}

runtime_install_configs() {
  collect_codex_api_keys

  run_install_triplet_stage "Updating Codex config" install_codex_config "skip" "none" "none" \
    INSTALL_CONFIG_ACTION INSTALL_CONFIG_STATE INSTALL_CONFIG_BACKUP
}

runtime_write_manifest() {
  local skills_string="${INSTALL_SKILL_NAMES[*]}"
  local rules_string="${INSTALL_RULE_NAMES[*]}"

  if dry_run_enabled; then
    printf '[dry-run] write manifest %s\n' "$MANIFEST_DST" >&2
    return 0
  fi

  ensure_dir "$METADATA_DIR"
  env \
    MANIFEST_DST="$MANIFEST_DST" \
    TIMESTAMP="$TIMESTAMP" \
    RUNTIME="$RUNTIME" \
    MEMORY_ACTION="$INSTALL_MEMORY_ACTION" \
    ACTIVATION_STATE="$INSTALL_ACTIVATION_STATE" \
    MEMORY_BACKUP="$INSTALL_MEMORY_BACKUP" \
    CONFIG_ACTION="$INSTALL_CONFIG_ACTION" \
    CONFIG_STATE="$INSTALL_CONFIG_STATE" \
    CONFIG_BACKUP="$INSTALL_CONFIG_BACKUP" \
    CODEX_DIR="$CODEX_DIR" \
    CODEX_CONFIG_DST="$CODEX_CONFIG_DST" \
    SKILLS_DST="$SKILLS_DST" \
    RULES_DST="$RULES_DST" \
    REFERENCES_DST="$REFERENCES_DST" \
    TEMPLATES_DST="$TEMPLATES_DST" \
    KERNEL_DST="$KERNEL_DST" \
    SKILLS="$skills_string" \
    RULES="$rules_string" \
    python3 - <<'PY'
import json
import os
from pathlib import Path

skills = [name for name in os.environ['SKILLS'].split() if name]
rules = [name for name in os.environ['RULES'].split() if name]
manifest = {
    'suite': 'b-agentic',
    'runtime': os.environ['RUNTIME'],
    'installedAt': os.environ['TIMESTAMP'],
    'activationState': os.environ['ACTIVATION_STATE'],
    'memoryAction': os.environ['MEMORY_ACTION'],
    'configAction': os.environ['CONFIG_ACTION'],
    'configState': os.environ['CONFIG_STATE'],
    'paths': {
        'codexDir': os.environ['CODEX_DIR'],
        'codexConfig': os.environ['CODEX_CONFIG_DST'],
        'kernel': os.environ['KERNEL_DST'],
        'skills': os.environ['SKILLS_DST'],
        'rules': os.environ['RULES_DST'],
        'references': os.environ['REFERENCES_DST'],
        'templates': os.environ['TEMPLATES_DST'],
    },
    'skills': skills,
    'rules': rules,
    'backups': {
        'codexConfig': os.environ['CONFIG_BACKUP'],
    },
}
Path(os.environ['MANIFEST_DST']).write_text(json.dumps(manifest, indent=2, sort_keys=True) + '\n')
PY
}

runtime_print_install_report() {
  print_install_report_header "Codex CLI"
  report_section "Summary"
  report_item "activation" "$INSTALL_ACTIVATION_STATE"
  report_item "skills" "${#INSTALL_SKILL_NAMES[@]} synced -> $SKILLS_DST"
  report_item "rules" "${#INSTALL_RULE_NAMES[@]} synced -> $RULES_DST"
  report_item "kernel" "$INSTALL_MEMORY_ACTION -> $KERNEL_DST"
  report_item "config" "$INSTALL_CONFIG_ACTION -> $CODEX_CONFIG_DST"
  report_item "references" "sync -> $REFERENCES_DST"
  report_item "templates" "sync -> $TEMPLATES_DST"
  report_item "manifest" "write -> $MANIFEST_DST"
  report_section "Backups"
  report_item "kernel" "$INSTALL_MEMORY_BACKUP"
  report_item "config" "$INSTALL_CONFIG_BACKUP"
  print_install_report_readiness
  print_shell_tool_recommendations
  print_install_report_next_steps "Codex CLI"
}

remove_codex_config_block() {
  local path="$1"
  [ -f "$path" ] || return 0

  if dry_run_enabled; then
    printf '[dry-run] remove managed Codex config block from %s\n' "$path" >&2
    return 0
  fi

  local tmp rc
  tmp="$(mktemp "${TMPDIR:-/tmp}/b-agentic-codex-uninstall.XXXXXX")"
  if env \
    CODEX_CONFIG_DST="$path" \
    CODEX_MANAGED_BEGIN="$CODEX_MANAGED_BEGIN" \
    CODEX_MANAGED_END="$CODEX_MANAGED_END" \
    JSON_TMP="$tmp" \
    python3 - <<'PY'
import os
from pathlib import Path

path = Path(os.environ['CODEX_CONFIG_DST'])
begin = os.environ['CODEX_MANAGED_BEGIN']
end = os.environ['CODEX_MANAGED_END']
tmp = Path(os.environ['JSON_TMP'])
text = path.read_text()

if begin not in text:
    raise SystemExit(2)
if end not in text:
    raise SystemExit('invalid Codex config: missing managed block terminator')

prefix, remainder = text.split(begin, 1)
_managed_body, suffix = remainder.split(end, 1)
cleaned = (prefix + suffix).strip()
if not cleaned:
    raise SystemExit(3)
tmp.write_text(cleaned + '\n')
PY
  then
    rc=0
  else
    rc=$?
  fi

  if [ "$rc" -eq 2 ]; then
    rm -f "$tmp"
    return 0
  fi
  if [ "$rc" -eq 3 ]; then
    rm -f "$tmp"
    run_cmd rm -f "$path"
    return 0
  fi
  if [ "$rc" -ne 0 ]; then
    rm -f "$tmp"
    warn "preserving modified Codex config: $path"
    return 0
  fi

  run_cmd mv "$tmp" "$path"
}

runtime_uninstall_configs() {
  local codex_config_path
  codex_config_path="$(manifest_path_value codexConfig "$CODEX_CONFIG_DST")"
  remove_codex_config_block "$codex_config_path"
}

runtime_install_extra_assets() {
  install_managed_profiles "$RULES_SRC" "$RULES_DST" "$RULES_SNAPSHOT_DST" "rules" "Codex rule" INSTALL_RULE_NAMES
  install_uninstall_helper
}

runtime_uninstall_extra_assets() {
  local rules_path
  rules_path="$(manifest_path_value rules "$RULES_DST")"
  uninstall_managed_profiles rules "$rules_path" "$RULES_SNAPSHOT_DST" "rules" "Codex rule"
}

# Codex does not reuse runtime_install_common: it injects MCP API keys as TOML
# literals inside the managed config block during install_codex_config, so it
# omits the generic JSON prompted-keys stage (collect_api_keys /
# apply_prompted_mcp_keys) that common.sh runs for JSON runtimes. Keep this flow
# in sync with runtime_install_common for the shared stages (skills, references,
# kernel, manifest, activation exit code 2).
runtime_main() {
  runtime_warn_missing_cli
  runtime_require_tomllib
  set_install_stage_total 7

  collect_installed_skills INSTALL_SKILL_NAMES
  run_stage "Preparing runtime CLI" runtime_upgrade_cli
  run_stage "Syncing skills" install_skills
  run_stage "Installing runtime extras" runtime_install_extra_assets
  run_stage "Syncing references and templates" install_references_and_templates

  run_install_triplet_stage "Installing kernel" install_kernel "preserve" "pending" "none" \
    INSTALL_MEMORY_ACTION INSTALL_ACTIVATION_STATE INSTALL_MEMORY_BACKUP

  runtime_install_configs
  run_stage "Writing install manifest" runtime_write_manifest
  runtime_print_install_report

  if [ "$INSTALL_ACTIVATION_STATE" = "pending" ]; then
    return 2
  fi
}

runtime_uninstall() {
  require_bin python3
  set_install_stage_total 4
  log "Uninstalling b-agentic from $RUNTIME_UNINSTALL_LABEL"
  run_stage "Removing managed skills" uninstall_installed_skills
  run_stage "Removing runtime extras" runtime_uninstall_extra_assets
  run_stage "Removing managed kernel" remove_managed_kernel
  run_stage "Cleaning runtime config" runtime_uninstall_configs
  run_cmd rm -rf "$METADATA_DIR"
  log "Uninstall complete. User-owned $RUNTIME_PRESERVE_LABEL files were preserved."
}
