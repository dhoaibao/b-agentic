# Sourced by install.sh — do not run directly.
# shellcheck shell=bash
# Variables below are shared with the sourced installer core.
# shellcheck disable=SC2034
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
	echo "error: this script is sourced by install.sh" >&2
	exit 1
fi

# Bash 3.2 keeps readonly declarations sourced inside a function local.
# Assign globally first, then mark the existing variables readonly through a
# helper so the installer remains compatible with macOS's default Bash.
set_pi_readonly() {
	readonly "$@"
}

RUNTIME_UNINSTALL_LABEL="Pi personal config"
RUNTIME_PRESERVE_LABEL="Pi"
PI_AGENT_DIR="${B_AGENTIC_PI_AGENT_DIR:-$HOME/.pi/agent}"
METADATA_DIR="$PI_AGENT_DIR/b-agentic"
BACKUPS_DIR="$METADATA_DIR/backups"
SKILLS_DST="$PI_AGENT_DIR/skills"
SKILLS_SNAPSHOT_DST="$METADATA_DIR/skills"
KERNEL_DST="$PI_AGENT_DIR/AGENTS.md"
KERNEL_SNAPSHOT_DST="$METADATA_DIR/AGENTS.md"
REFERENCES_DST="$METADATA_DIR/references"
CAPABILITIES_SRC="$SOURCE_DIR/references/capabilities.yaml"
TEMPLATES_DST="$METADATA_DIR/templates"
MANIFEST_DST="$METADATA_DIR/install.json"
MCP_CONFIG_DST="${B_AGENTIC_PI_MCP_JSON:-$PI_AGENT_DIR/mcp.json}"
EXTENSIONS_DST="$PI_AGENT_DIR/extensions"
THEMES_DST="$PI_AGENT_DIR/themes"
THEME_DST="$THEMES_DST/dracula.json"
THEMES_SNAPSHOT_DST="$METADATA_DIR/themes"
THEME_CACHED_DST="$THEMES_SNAPSHOT_DST/dracula.json"
DRACULA_REPO_URL="${B_AGENTIC_DRACULA_REPO:-https://github.com/dracula/pi-coding-agent.git}"
EXTENSION_NAMES=(
	b-agentic-preview-markdown.ts
	b-agentic-permissions.ts
	b-agentic-mcp-permissions.ts
	b-agentic-auto-mode.ts
	b-agentic-sync.ts
	b-agentic-status.ts
	b-agentic-support/shell.ts
	b-agentic-support/mcp.ts
	b-agentic-support/permissions-data.ts
	b-agentic-support/worker.ts
	b-agentic-support/state.ts
	b-agentic-support/auto.ts
	b-agentic-support/capabilities.ts
	b-agentic-support/status.ts
)
LEGACY_EXTENSION_NAMES=(
	b-agentic-planner.ts
	b-agentic-planner-notify.ts
	b-agentic-worker.ts
	b-agentic-consult.ts
	b-agentic-consultant.ts
	b-agentic-rule-guard.ts
	b-agentic-support/consult.ts
	b-agentic-role.ts
	b-agentic-architect.ts
	b-agentic-executor.ts
	b-agentic-executor-notify.ts
	b-agentic-support/role.ts
	b-agentic-support/role-models.ts
	b-agentic-support/role-store.ts
	b-agentic-support/candidate.ts
)
EXTENSION_DST="$EXTENSIONS_DST/b-agentic-permissions.ts"
EXTENSION_SNAPSHOT_DST="$METADATA_DIR/extensions/b-agentic-permissions.ts"
EXTENSION_SRC="$SOURCE_DIR/adapters/pi/extensions/b-agentic-permissions.ts"
PI_MCP_ADAPTER_SPEC="npm:pi-mcp-adapter"
PI_MCP_ADAPTER_PACKAGE="pi-mcp-adapter"
PI_OBSERVATIONAL_MEMORY_SPEC="npm:pi-observational-memory"
PI_OBSERVATIONAL_MEMORY_PACKAGE="pi-observational-memory"
PI_USAGE_SPEC="npm:@sreetej510/pi-usage"
PI_USAGE_PACKAGE="@sreetej510/pi-usage"
PI_ANTHROPIC_AUTH_SPEC="npm:@gotgenes/pi-anthropic-auth"
PI_ANTHROPIC_AUTH_PACKAGE="@gotgenes/pi-anthropic-auth"
PI_INTERCOM_SPEC="npm:pi-intercom"
PI_INTERCOM_PACKAGE="pi-intercom"
PI_ASK_USER_QUESTION_SPEC="npm:@juicesharp/rpiv-ask-user-question"
PI_ASK_USER_QUESTION_PACKAGE="@juicesharp/rpiv-ask-user-question"
PI_TODO_SPEC="npm:@juicesharp/rpiv-todo"
PI_TODO_PACKAGE="@juicesharp/rpiv-todo"
MCP_ROOT_KEY="mcpServers"
MCP_PLACEHOLDER_STYLE="env-brace"
MCP_CONTEXT7_SECTION="headers"
MCP_BRAVE_SECTION="env"
MCP_FIRECRAWL_SECTION="env"
MCP_BACKUP_KEY="mcpConfig"
EXTENSION_BACKUP_KEY="permissionsExtension"

set_pi_readonly \
	RUNTIME_UNINSTALL_LABEL RUNTIME_PRESERVE_LABEL PI_AGENT_DIR METADATA_DIR \
	BACKUPS_DIR SKILLS_DST SKILLS_SNAPSHOT_DST KERNEL_DST KERNEL_SNAPSHOT_DST \
	REFERENCES_DST CAPABILITIES_SRC TEMPLATES_DST MANIFEST_DST MCP_CONFIG_DST EXTENSIONS_DST \
	EXTENSION_NAMES LEGACY_EXTENSION_NAMES EXTENSION_DST EXTENSION_SNAPSHOT_DST EXTENSION_SRC \
	PI_MCP_ADAPTER_SPEC PI_MCP_ADAPTER_PACKAGE PI_OBSERVATIONAL_MEMORY_SPEC \
	PI_OBSERVATIONAL_MEMORY_PACKAGE PI_USAGE_SPEC PI_USAGE_PACKAGE \
	PI_ANTHROPIC_AUTH_SPEC PI_ANTHROPIC_AUTH_PACKAGE PI_INTERCOM_SPEC PI_INTERCOM_PACKAGE \
	PI_ASK_USER_QUESTION_SPEC PI_ASK_USER_QUESTION_PACKAGE \
	PI_TODO_SPEC PI_TODO_PACKAGE MCP_ROOT_KEY MCP_PLACEHOLDER_STYLE \
	MCP_CONTEXT7_SECTION MCP_BRAVE_SECTION MCP_FIRECRAWL_SECTION MCP_BACKUP_KEY \
	EXTENSION_BACKUP_KEY THEMES_DST THEME_DST THEMES_SNAPSHOT_DST THEME_CACHED_DST \
	DRACULA_REPO_URL

CONTEXT7_API_KEY_INPUT=""
BRAVE_API_KEY_INPUT=""
FIRECRAWL_API_KEY_INPUT=""
FIRECRAWL_API_URL_INPUT=""
INSTALL_MCP_ACTION="skip"
INSTALL_MCP_STATE="none"
INSTALL_MCP_BACKUP="none"
INSTALL_EXTENSION_ACTION="skip"
INSTALL_EXTENSION_STATE="none"
INSTALL_EXTENSION_BACKUP="none"
INSTALL_PI_MCP_ADAPTER_ACTION="skip"
INSTALL_PI_MCP_ADAPTER_STATE="missing"
INSTALL_PI_OBSERVATIONAL_MEMORY_ACTION="skip"
INSTALL_PI_OBSERVATIONAL_MEMORY_STATE="missing"
INSTALL_PI_USAGE_ACTION="skip"
INSTALL_PI_USAGE_STATE="missing"
INSTALL_PI_ANTHROPIC_AUTH_ACTION="skip"
INSTALL_PI_ANTHROPIC_AUTH_STATE="missing"
INSTALL_PI_INTERCOM_ACTION="skip"
INSTALL_PI_INTERCOM_STATE="missing"
INSTALL_PI_ASK_USER_QUESTION_ACTION="skip"
INSTALL_PI_ASK_USER_QUESTION_STATE="missing"
INSTALL_PI_TODO_ACTION="skip"
INSTALL_PI_TODO_STATE="missing"
INSTALL_THEME_ACTION="skip"
INSTALL_THEME_STATE="none"

runtime_warn_missing_cli() {
	command -v pi >/dev/null 2>&1 || warn "Pi CLI 'pi' not found; files will still be installed for Pi to discover later."
	command -v codegraph >/dev/null 2>&1 || warn "codegraph CLI not found; CodeGraph MCP will not start until CodeGraph is installed."
	command -v bunx >/dev/null 2>&1 || warn "bunx not found; MCP servers that use bunx (Brave, Firecrawl, Playwright) will not start until Bun is installed."
	if installer_component_enabled mcp && command -v pi >/dev/null 2>&1 && ! pi_mcp_adapter_installed; then
		warn "pi-mcp-adapter not installed; MCP servers will not load until the adapter is installed."
	fi
	if installer_component_enabled pi-integrations && command -v pi >/dev/null 2>&1; then
		if ! pi_observational_memory_installed; then
			warn "pi-observational-memory not installed; long-session compaction continuity is unavailable."
		fi
		if ! pi_usage_installed; then
			warn "@sreetej510/pi-usage not installed; Pi usage reporting is unavailable."
		fi
		if ! pi_anthropic_auth_installed; then
			warn "@gotgenes/pi-anthropic-auth not installed; Anthropic authentication support is unavailable."
		fi
		if ! pi_ask_user_question_installed; then
			warn "@juicesharp/rpiv-ask-user-question not installed; interactive user questions are unavailable."
		fi
		if ! pi_todo_installed; then
			warn "@juicesharp/rpiv-todo not installed; the Pi todo tool, /todos command, and persistent overlay are unavailable."
		fi
	fi
}

runtime_cli_installed() {
	command -v pi >/dev/null 2>&1
}

runtime_update_cli() {
	if ! command -v pi >/dev/null 2>&1; then
		warn "Pi CLI not found; skipping Pi update"
		return 0
	fi
	if dry_run_enabled; then
		printf '[dry-run] pi update\n' >&2
		return 0
	fi
	log "Updating Pi CLI with pi update"
	if pi update; then
		log "Pi CLI update completed"
	else
		warn "Pi CLI update failed"
		return 1
	fi
}

runtime_upgrade_cli() {
	local command
	if command -v pi >/dev/null 2>&1; then
		command="pi update"
		log "Pi CLI already installed; upgrading with pi update"
	else
		command="curl -fsSL https://pi.dev/install.sh | sh"
		log "Pi CLI not found; installing with the Pi installer"
	fi
	if dry_run_enabled; then
		printf '[dry-run] %s\n' "$command" >&2
		return 0
	fi
	if [ "$command" = "pi update" ]; then
		if pi update; then
			log "Pi CLI install/upgrade completed"
		else
			warn "Pi CLI install/upgrade failed"
			return 1
		fi
	elif curl -fsSL https://pi.dev/install.sh | sh; then
		log "Pi CLI install/upgrade completed"
	else
		warn "Pi CLI install/upgrade failed"
		return 1
	fi
	return 0
}

pi_package_state() {
	local package="$1"
	if ! command -v pi >/dev/null 2>&1; then
		printf 'missing\n'
		return 0
	fi
	local listing
	# Bind to current HOME so sandbox / alternate-home installs do not
	# report a global package install as ready for this target.
	local target_home="${HOME}" target_pi_dir="${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}"
	listing="$(
		HOME="$target_home" \
			PI_CODING_AGENT_DIR="$target_pi_dir" \
			pi list 2>/dev/null || true
	)"
	if printf '%s\n' "$listing" | grep -Eq "(^|[[:space:]])npm:${package}([[:space:]]|$)|(^|[[:space:]])${package}([[:space:]]|$)"; then
		printf 'present\n'
	elif printf '%s\n' "$listing" | grep -Eq "(^|[[:space:]])npm:${package}@|(^|[[:space:]])${package}@"; then
		printf 'versioned\n'
	else
		printf 'missing\n'
	fi
}

pi_package_installed() {
	[ "$(pi_package_state "$1")" != "missing" ]
}

pi_mcp_adapter_installed() {
	pi_package_installed "$PI_MCP_ADAPTER_PACKAGE"
}

pi_observational_memory_installed() {
	pi_package_installed "$PI_OBSERVATIONAL_MEMORY_PACKAGE"
}

pi_usage_installed() {
	pi_package_installed "$PI_USAGE_PACKAGE"
}

pi_anthropic_auth_installed() {
	pi_package_installed "$PI_ANTHROPIC_AUTH_PACKAGE"
}

pi_intercom_installed() {
	pi_package_installed "$PI_INTERCOM_PACKAGE"
}

pi_ask_user_question_installed() {
	pi_package_installed "$PI_ASK_USER_QUESTION_PACKAGE"
}

pi_todo_installed() {
	pi_package_installed "$PI_TODO_PACKAGE"
}

maybe_install_pi_mcp_adapter() {
	if pi_mcp_adapter_installed; then
		INSTALL_PI_MCP_ADAPTER_ACTION="present"
		INSTALL_PI_MCP_ADAPTER_STATE="ready"
		log "Pi MCP adapter $PI_MCP_ADAPTER_PACKAGE already installed"
		return 0
	fi

	if ! command -v pi >/dev/null 2>&1 && ! dry_run_enabled; then
		warn "Pi CLI missing; cannot install $PI_MCP_ADAPTER_PACKAGE"
		return 1
	fi


	if dry_run_enabled; then
		printf '[dry-run] pi install %s\n' "$PI_MCP_ADAPTER_SPEC" >&2
		INSTALL_PI_MCP_ADAPTER_ACTION="install"
		INSTALL_PI_MCP_ADAPTER_STATE="dry-run"
		return 0
	fi

	log "Installing $PI_MCP_ADAPTER_PACKAGE"
	if pi install "$PI_MCP_ADAPTER_SPEC"; then
		INSTALL_PI_MCP_ADAPTER_ACTION="install"
		INSTALL_PI_MCP_ADAPTER_STATE="ready"
		log "Installed $PI_MCP_ADAPTER_PACKAGE"
	else
		INSTALL_PI_MCP_ADAPTER_ACTION="failed"
		INSTALL_PI_MCP_ADAPTER_STATE="missing"
		warn "Failed to install $PI_MCP_ADAPTER_PACKAGE"
		return 1
	fi
}

maybe_install_pi_usage() {
	if pi_usage_installed; then
		INSTALL_PI_USAGE_ACTION="present"
		INSTALL_PI_USAGE_STATE="ready"
		log "Pi Usage $PI_USAGE_PACKAGE already installed"
		return 0
	fi

	if ! command -v pi >/dev/null 2>&1 && ! dry_run_enabled; then
		warn "Pi CLI missing; cannot install $PI_USAGE_PACKAGE"
		return 1
	fi


	if dry_run_enabled; then
		printf '[dry-run] pi install %s\n' "$PI_USAGE_SPEC" >&2
		INSTALL_PI_USAGE_ACTION="install"
		INSTALL_PI_USAGE_STATE="dry-run"
		return 0
	fi

	log "Installing $PI_USAGE_PACKAGE"
	if pi install "$PI_USAGE_SPEC"; then
		INSTALL_PI_USAGE_ACTION="install"
		INSTALL_PI_USAGE_STATE="ready"
		log "Installed $PI_USAGE_PACKAGE"
	else
		INSTALL_PI_USAGE_ACTION="failed"
		INSTALL_PI_USAGE_STATE="missing"
		warn "Failed to install $PI_USAGE_PACKAGE"
		return 1
	fi
}

maybe_install_pi_anthropic_auth() {
	if pi_anthropic_auth_installed; then
		INSTALL_PI_ANTHROPIC_AUTH_ACTION="present"
		INSTALL_PI_ANTHROPIC_AUTH_STATE="ready"
		log "Pi Anthropic auth $PI_ANTHROPIC_AUTH_PACKAGE already installed"
		return 0
	fi

	if ! command -v pi >/dev/null 2>&1 && ! dry_run_enabled; then
		warn "Pi CLI missing; cannot install $PI_ANTHROPIC_AUTH_PACKAGE"
		return 1
	fi

	if dry_run_enabled; then
		printf '[dry-run] pi install %s\n' "$PI_ANTHROPIC_AUTH_SPEC" >&2
		INSTALL_PI_ANTHROPIC_AUTH_ACTION="install"
		INSTALL_PI_ANTHROPIC_AUTH_STATE="dry-run"
		return 0
	fi

	log "Installing $PI_ANTHROPIC_AUTH_PACKAGE"
	if pi install "$PI_ANTHROPIC_AUTH_SPEC"; then
		INSTALL_PI_ANTHROPIC_AUTH_ACTION="install"
		INSTALL_PI_ANTHROPIC_AUTH_STATE="ready"
		log "Installed $PI_ANTHROPIC_AUTH_PACKAGE"
	else
		INSTALL_PI_ANTHROPIC_AUTH_ACTION="failed"
		INSTALL_PI_ANTHROPIC_AUTH_STATE="missing"
		warn "Failed to install $PI_ANTHROPIC_AUTH_PACKAGE"
		return 1
	fi
}

maybe_install_pi_intercom() {
	if pi_intercom_installed; then INSTALL_PI_INTERCOM_ACTION="present"; INSTALL_PI_INTERCOM_STATE="ready"; return 0; fi
	if ! command -v pi >/dev/null 2>&1 && ! dry_run_enabled; then warn "Pi CLI missing; cannot install $PI_INTERCOM_PACKAGE"; return 1; fi
	if dry_run_enabled; then
		printf '[dry-run] pi install %s\n' "$PI_INTERCOM_SPEC" >&2
		INSTALL_PI_INTERCOM_ACTION="install"; INSTALL_PI_INTERCOM_STATE="dry-run"; return 0
	fi
	if pi install "$PI_INTERCOM_SPEC"; then
		INSTALL_PI_INTERCOM_ACTION="install"; INSTALL_PI_INTERCOM_STATE="ready"
	else
		INSTALL_PI_INTERCOM_ACTION="failed"; INSTALL_PI_INTERCOM_STATE="missing"
		warn "Failed to install $PI_INTERCOM_PACKAGE"
		return 1
	fi
}

maybe_install_pi_ask_user_question() {
	local package_state
	package_state="$(pi_package_state "$PI_ASK_USER_QUESTION_PACKAGE")"
	if [ "$package_state" = "present" ]; then
		INSTALL_PI_ASK_USER_QUESTION_ACTION="present"
		INSTALL_PI_ASK_USER_QUESTION_STATE="ready"
		log "Pi Ask User Question $PI_ASK_USER_QUESTION_PACKAGE already installed"
		return 0
	fi

	if ! command -v pi >/dev/null 2>&1 && ! dry_run_enabled; then
		warn "Pi CLI missing; cannot install $PI_ASK_USER_QUESTION_PACKAGE"
		return 1
	fi

	if dry_run_enabled; then
		printf '[dry-run] pi install %s\n' "$PI_ASK_USER_QUESTION_SPEC" >&2
		INSTALL_PI_ASK_USER_QUESTION_ACTION="install"
		INSTALL_PI_ASK_USER_QUESTION_STATE="dry-run"
		return 0
	fi

	if [ "$package_state" = "versioned" ]; then
		log "Migrating $PI_ASK_USER_QUESTION_PACKAGE to its latest unpinned release"
	else
		log "Installing $PI_ASK_USER_QUESTION_PACKAGE"
	fi
	if pi install "$PI_ASK_USER_QUESTION_SPEC"; then
		INSTALL_PI_ASK_USER_QUESTION_ACTION="install"
		INSTALL_PI_ASK_USER_QUESTION_STATE="ready"
		log "Installed $PI_ASK_USER_QUESTION_PACKAGE"
	else
		INSTALL_PI_ASK_USER_QUESTION_ACTION="failed"
		INSTALL_PI_ASK_USER_QUESTION_STATE="missing"
		warn "Failed to install $PI_ASK_USER_QUESTION_PACKAGE"
		return 1
	fi
}

maybe_install_pi_todo() {
	local package_state
	package_state="$(pi_package_state "$PI_TODO_PACKAGE")"
	if [ "$package_state" = "present" ]; then
		INSTALL_PI_TODO_ACTION="present"
		INSTALL_PI_TODO_STATE="ready"
		log "Pi Todo $PI_TODO_PACKAGE already installed"
		return 0
	fi

	if ! command -v pi >/dev/null 2>&1 && ! dry_run_enabled; then
		warn "Pi CLI missing; cannot install $PI_TODO_PACKAGE"
		return 1
	fi

	if dry_run_enabled; then
		printf '[dry-run] pi install %s\n' "$PI_TODO_SPEC" >&2
		INSTALL_PI_TODO_ACTION="install"
		INSTALL_PI_TODO_STATE="dry-run"
		return 0
	fi

	if [ "$package_state" = "versioned" ]; then
		log "Migrating $PI_TODO_PACKAGE to its latest unpinned release"
	else
		log "Installing $PI_TODO_PACKAGE"
	fi
	if pi install "$PI_TODO_SPEC"; then
		INSTALL_PI_TODO_ACTION="install"
		INSTALL_PI_TODO_STATE="ready"
		log "Installed $PI_TODO_PACKAGE"
	else
		INSTALL_PI_TODO_ACTION="failed"
		INSTALL_PI_TODO_STATE="missing"
		warn "Failed to install $PI_TODO_PACKAGE"
		return 1
	fi
}

maybe_install_pi_observational_memory() {
	if pi_observational_memory_installed; then
		INSTALL_PI_OBSERVATIONAL_MEMORY_ACTION="present"
		INSTALL_PI_OBSERVATIONAL_MEMORY_STATE="ready"
		log "Pi Observational Memory $PI_OBSERVATIONAL_MEMORY_PACKAGE already installed"
		return 0
	fi

	if ! command -v pi >/dev/null 2>&1 && ! dry_run_enabled; then
		warn "Pi CLI missing; cannot install $PI_OBSERVATIONAL_MEMORY_PACKAGE"
		return 1
	fi


	if dry_run_enabled; then
		printf '[dry-run] pi install %s\n' "$PI_OBSERVATIONAL_MEMORY_SPEC" >&2
		INSTALL_PI_OBSERVATIONAL_MEMORY_ACTION="install"
		INSTALL_PI_OBSERVATIONAL_MEMORY_STATE="dry-run"
		return 0
	fi

	log "Installing $PI_OBSERVATIONAL_MEMORY_PACKAGE"
	if pi install "$PI_OBSERVATIONAL_MEMORY_SPEC"; then
		INSTALL_PI_OBSERVATIONAL_MEMORY_ACTION="install"
		INSTALL_PI_OBSERVATIONAL_MEMORY_STATE="ready"
		log "Installed $PI_OBSERVATIONAL_MEMORY_PACKAGE"
	else
		INSTALL_PI_OBSERVATIONAL_MEMORY_ACTION="failed"
		INSTALL_PI_OBSERVATIONAL_MEMORY_STATE="missing"
		warn "Failed to install $PI_OBSERVATIONAL_MEMORY_PACKAGE"
		return 1
	fi
}

install_selected_pi_packages() {
	if installer_component_enabled mcp; then
		maybe_install_pi_mcp_adapter || return $?
	fi
	if installer_component_enabled pi-integrations; then
		maybe_install_pi_observational_memory || return $?
		maybe_install_pi_usage || return $?
		maybe_install_pi_anthropic_auth || return $?
		maybe_install_pi_intercom || return $?
		maybe_install_pi_ask_user_question || return $?
		maybe_install_pi_todo || return $?
	fi
}

preserve_skipped_component_state() {
	if ! installer_component_enabled mcp; then
		INSTALL_MCP_ACTION="$(manifest_action_value mcpAction "$INSTALL_MCP_ACTION")"
		INSTALL_MCP_STATE="$(manifest_action_value mcpState "$INSTALL_MCP_STATE")"
		INSTALL_MCP_BACKUP="$(manifest_backup_value mcpConfig "$INSTALL_MCP_BACKUP")"
		INSTALL_PI_MCP_ADAPTER_ACTION="$(manifest_action_value mcpAdapterAction "$INSTALL_PI_MCP_ADAPTER_ACTION")"
		INSTALL_PI_MCP_ADAPTER_STATE="$(manifest_action_value mcpAdapterState "$INSTALL_PI_MCP_ADAPTER_STATE")"
	fi

	if ! installer_component_enabled pi-integrations; then
		INSTALL_PI_OBSERVATIONAL_MEMORY_ACTION="$(manifest_action_value piObservationalMemoryAction "$INSTALL_PI_OBSERVATIONAL_MEMORY_ACTION")"
		INSTALL_PI_OBSERVATIONAL_MEMORY_STATE="$(manifest_action_value piObservationalMemoryState "$INSTALL_PI_OBSERVATIONAL_MEMORY_STATE")"
		INSTALL_PI_USAGE_ACTION="$(manifest_action_value piUsageAction "$INSTALL_PI_USAGE_ACTION")"
		INSTALL_PI_USAGE_STATE="$(manifest_action_value piUsageState "$INSTALL_PI_USAGE_STATE")"
		INSTALL_PI_ANTHROPIC_AUTH_ACTION="$(manifest_action_value piAnthropicAuthAction "$INSTALL_PI_ANTHROPIC_AUTH_ACTION")"
		INSTALL_PI_ANTHROPIC_AUTH_STATE="$(manifest_action_value piAnthropicAuthState "$INSTALL_PI_ANTHROPIC_AUTH_STATE")"
		INSTALL_PI_INTERCOM_ACTION="$(manifest_action_value piIntercomAction "$INSTALL_PI_INTERCOM_ACTION")"
		INSTALL_PI_INTERCOM_STATE="$(manifest_action_value piIntercomState "$INSTALL_PI_INTERCOM_STATE")"
		INSTALL_PI_ASK_USER_QUESTION_ACTION="$(manifest_action_value piAskUserQuestionAction "$INSTALL_PI_ASK_USER_QUESTION_ACTION")"
		INSTALL_PI_ASK_USER_QUESTION_STATE="$(manifest_action_value piAskUserQuestionState "$INSTALL_PI_ASK_USER_QUESTION_STATE")"
		INSTALL_PI_TODO_ACTION="$(manifest_action_value piTodoAction "$INSTALL_PI_TODO_ACTION")"
		INSTALL_PI_TODO_STATE="$(manifest_action_value piTodoState "$INSTALL_PI_TODO_STATE")"
	fi

	if ! installer_component_enabled theme; then
		INSTALL_THEME_ACTION="$(manifest_action_value themeAction "$INSTALL_THEME_ACTION")"
		INSTALL_THEME_STATE="$(manifest_action_value themeState "$INSTALL_THEME_STATE")"
	fi
}

runtime_install_config_stage_count() {
	local count=2
	if installer_component_enabled mcp || installer_component_enabled pi-integrations; then
		count=$((count + 1))
	fi
	if installer_component_enabled mcp; then
		count=$((count + 2))
	fi
	if installer_component_enabled theme; then
		count=$((count + 1))
	fi
	printf '%s' "$count"
}

install_dracula_theme() {
	local tmp_clone=""
	local repo_url="${DRACULA_REPO_URL:-https://github.com/dracula/pi-coding-agent.git}"

	if dry_run_enabled; then
		printf '[dry-run] git clone --depth 1 %s <tmpdir>\n' "$repo_url" >&2
		printf '[dry-run] copy dracula.json -> %s\n' "$THEME_CACHED_DST" >&2
		printf '[dry-run] ln -sfn %s %s\n' "$THEME_CACHED_DST" "$THEME_DST" >&2
		INSTALL_THEME_ACTION="write"
		INSTALL_THEME_STATE="dry-run"
		return 0
	fi

	require_bin git
	require_bin python3

	tmp_clone="$(mktemp -d "${TMPDIR:-/tmp}/b-agentic-dracula.XXXXXX")"
	cleanup_dracula_clone() {
		if [ -n "$tmp_clone" ] && [ -d "$tmp_clone" ]; then
			rm -rf "$tmp_clone"
		fi
	}

	if ! git clone --depth 1 --quiet "$repo_url" "$tmp_clone"; then
		cleanup_dracula_clone
		warn "failed to clone Dracula theme from $repo_url"
		INSTALL_THEME_ACTION="failed"
		INSTALL_THEME_STATE="missing"
		return 1
	fi

	if [ ! -f "$tmp_clone/dracula.json" ]; then
		cleanup_dracula_clone
		warn "missing dracula.json in Dracula theme repository"
		INSTALL_THEME_ACTION="failed"
		INSTALL_THEME_STATE="missing"
		return 1
	fi

	if ! python3 - "$tmp_clone/dracula.json" <<'PY'
import json
import sys
from pathlib import Path

try:
    data = json.loads(Path(sys.argv[1]).read_text())
    if not isinstance(data, dict):
        sys.exit(1)
except Exception:
    sys.exit(1)
sys.exit(0)
PY
	then
		cleanup_dracula_clone
		warn "invalid dracula.json in Dracula theme repository"
		INSTALL_THEME_ACTION="failed"
		INSTALL_THEME_STATE="missing"
		return 1
	fi

	if ! ensure_dir "$THEMES_SNAPSHOT_DST" || ! copy_file "$tmp_clone/dracula.json" "$THEME_CACHED_DST"; then
		cleanup_dracula_clone
		warn "failed to cache Dracula theme to $THEME_CACHED_DST"
		INSTALL_THEME_ACTION="failed"
		INSTALL_THEME_STATE="missing"
		return 1
	fi
	cleanup_dracula_clone

	ensure_dir "$THEMES_DST"
	if [ -L "$THEME_DST" ]; then
		local is_owned
		is_owned="$(python3 - "$THEME_DST" "$THEME_CACHED_DST" <<'PY'
import os
import sys
from pathlib import Path

dst = Path(sys.argv[1])
cached = Path(sys.argv[2])
try:
    target = Path(os.readlink(dst))
    if not target.is_absolute():
        target = dst.parent / target
    if target.resolve() == cached.resolve() or target == cached:
        print("yes")
    else:
        print("no")
except Exception:
    print("no")
PY
)"
		if [ "$is_owned" = "yes" ]; then
			run_cmd ln -sfn "$THEME_CACHED_DST" "$THEME_DST"
			INSTALL_THEME_ACTION="replace"
			INSTALL_THEME_STATE="ready"
		else
			warn "preserving symlinked Pi theme: $THEME_DST"
			INSTALL_THEME_ACTION="preserve"
			INSTALL_THEME_STATE="preserved"
		fi
	elif [ -e "$THEME_DST" ]; then
		warn "preserving user-owned theme file: $THEME_DST"
		INSTALL_THEME_ACTION="preserve"
		INSTALL_THEME_STATE="preserved"
	else
		run_cmd ln -s "$THEME_CACHED_DST" "$THEME_DST"
		INSTALL_THEME_ACTION="write"
		INSTALL_THEME_STATE="ready"
	fi
	return 0
}

remove_legacy_extensions() {
	local name dst snapshot
	for name in "${LEGACY_EXTENSION_NAMES[@]}"; do
		dst="$EXTENSIONS_DST/$name"
		snapshot="$METADATA_DIR/extensions/$name"
		if dry_run_enabled; then
			printf '[dry-run] remove legacy extension if managed %s\n' "$dst" >&2
			continue
		fi
		if [ -f "$dst" ] && [ -f "$snapshot" ] && cmp -s "$dst" "$snapshot"; then
			run_cmd rm -f "$dst" "$snapshot"
		elif [ ! -e "$dst" ] && [ ! -L "$dst" ] && [ -f "$snapshot" ] && [ ! -L "$snapshot" ]; then
			run_cmd rm -f "$snapshot"
		elif [ -e "$dst" ]; then
			warn "preserving user-modified legacy extension: $dst"
		fi
	done
}

install_permissions_extension() {
	local name src dst snapshot previous_backup backup action="skip" state="active" backups=()
	remove_legacy_extensions
	for name in "${EXTENSION_NAMES[@]}"; do
		if [ "$name" = "b-agentic-preview-markdown.ts" ]; then
			src="$SOURCE_DIR/adapters/pi/packages/preview-markdown/extensions/$name"
		else
			src="$SOURCE_DIR/adapters/pi/extensions/$name"
		fi
		if [ ! -f "$src" ]; then
			die "missing Pi extension source: $src"
		fi
		dst="$EXTENSIONS_DST/$name"
		snapshot="$METADATA_DIR/extensions/$name"
		previous_backup="$(manifest_backup_value "extension:$name" none)"
		[ "$previous_backup" = "none" ] && [ "$name" = "b-agentic-permissions.ts" ] && previous_backup="$(manifest_backup_value permissionsExtension none)"
		if [ "$previous_backup" != "none" ]; then
			backups+=("$name|$(printf '%s' "$previous_backup" | base64 | tr -d '\n')")
		fi
		if dry_run_enabled; then
			printf '[dry-run] install extension %s -> %s\n' "$src" "$dst" >&2
			action="write"
			continue
		fi
		ensure_dir "$EXTENSIONS_DST"
		ensure_dir "$(dirname "$snapshot")"
		if [ -L "$dst" ]; then
			backup="$(backup_file "$dst")"
			copy_file "$src" "$dst"
			[ -n "$backup" ] && backups+=("$name|$(printf '%s' "$backup" | base64 | tr -d '\n')")
			action="replace"
		elif [ -f "$dst" ]; then
			if cmp -s "$src" "$dst"; then
				action="${action/skip/skip}"
			elif [ -f "$snapshot" ] && cmp -s "$dst" "$snapshot"; then
				copy_file "$src" "$dst"
				action="replace"
			else
				backup="$(backup_file "$dst")"
				copy_file "$src" "$dst"
				[ -n "$backup" ] && backups+=("$name|$(printf '%s' "$backup" | base64 | tr -d '\n')")
				action="replace"
			fi
		else
			copy_file "$src" "$dst"
			action="write"
		fi
		copy_file "$src" "$snapshot"
	done
	if dry_run_enabled; then
		printf 'write\nactive\nnone'
	else
		printf '%s\n%s\n%s' "$action" "$state" "${backups[*]:-none}"
	fi
}

update_pi_extensions() {
	if ! command -v pi >/dev/null 2>&1 && ! dry_run_enabled; then
		warn "Pi CLI missing; cannot update Pi extensions"
		return 1
	fi
	if dry_run_enabled; then
		printf '[dry-run] pi update --extensions\n' >&2
		return 0
	fi

	log "Updating installed Pi extensions with pi update --extensions"
	if pi update --extensions; then
		log "Pi extension update completed"
	else
		warn "Pi extension update failed"
		return 1
	fi
	return 0
}

runtime_install_configs() {
	preserve_skipped_component_state

	if installer_component_enabled mcp || installer_component_enabled pi-integrations; then
		run_stage "Installing selected Pi packages" install_selected_pi_packages || return $?
	fi
	run_stage "Updating Pi extensions" update_pi_extensions || return $?
	run_install_triplet_stage "Installing Pi permission extension" install_permissions_extension "skip" "none" "none" \
		INSTALL_EXTENSION_ACTION INSTALL_EXTENSION_STATE INSTALL_EXTENSION_BACKUP || return $?
	if installer_component_enabled mcp; then
		run_install_triplet_stage "Merging MCP config" install_mcp_config "skip" "none" "none" \
		INSTALL_MCP_ACTION INSTALL_MCP_STATE INSTALL_MCP_BACKUP || return $?
		apply_prompted_mcp_keys_stage INSTALL_MCP_ACTION INSTALL_MCP_BACKUP || return $?
	fi
	if installer_component_enabled theme; then
		run_stage "Installing Dracula theme" install_dracula_theme || return $?
	fi
}

runtime_write_manifest() {
	local skills_string="${INSTALL_SKILL_NAMES[*]}"

	if dry_run_enabled; then
		printf '[dry-run] write manifest %s\n' "$MANIFEST_DST" >&2
		return 0
	fi

	ensure_dir "$METADATA_DIR"
	env \
		MANIFEST_DST="$MANIFEST_DST" \
		TIMESTAMP="$TIMESTAMP" \
		RUNTIME="pi" \
		MEMORY_ACTION="$INSTALL_MEMORY_ACTION" \
		ACTIVATION_STATE="$INSTALL_ACTIVATION_STATE" \
		MEMORY_BACKUP="$INSTALL_MEMORY_BACKUP" \
		EXTENSION_ACTION="$INSTALL_EXTENSION_ACTION" \
		EXTENSION_STATE="$INSTALL_EXTENSION_STATE" \
		EXTENSION_BACKUP="$INSTALL_EXTENSION_BACKUP" \
		MCP_ACTION="$INSTALL_MCP_ACTION" \
		MCP_STATE="$INSTALL_MCP_STATE" \
		MCP_BACKUP="$INSTALL_MCP_BACKUP" \
		MCP_ADAPTER_ACTION="$INSTALL_PI_MCP_ADAPTER_ACTION" \
		MCP_ADAPTER_STATE="$INSTALL_PI_MCP_ADAPTER_STATE" \
		PI_OBSERVATIONAL_MEMORY_ACTION="$INSTALL_PI_OBSERVATIONAL_MEMORY_ACTION" \
		PI_OBSERVATIONAL_MEMORY_STATE="$INSTALL_PI_OBSERVATIONAL_MEMORY_STATE" \
		PI_USAGE_ACTION="$INSTALL_PI_USAGE_ACTION" \
		PI_USAGE_STATE="$INSTALL_PI_USAGE_STATE" \
		PI_ANTHROPIC_AUTH_ACTION="$INSTALL_PI_ANTHROPIC_AUTH_ACTION" \
		PI_ANTHROPIC_AUTH_STATE="$INSTALL_PI_ANTHROPIC_AUTH_STATE" \
		PI_INTERCOM_ACTION="$INSTALL_PI_INTERCOM_ACTION" \
		PI_INTERCOM_STATE="$INSTALL_PI_INTERCOM_STATE" \
		PI_ASK_USER_QUESTION_ACTION="$INSTALL_PI_ASK_USER_QUESTION_ACTION" \
		PI_ASK_USER_QUESTION_STATE="$INSTALL_PI_ASK_USER_QUESTION_STATE" \
		PI_TODO_ACTION="$INSTALL_PI_TODO_ACTION" \
		PI_TODO_STATE="$INSTALL_PI_TODO_STATE" \
		THEME_ACTION="$INSTALL_THEME_ACTION" \
		THEME_STATE="$INSTALL_THEME_STATE" \
		PI_AGENT_DIR="$PI_AGENT_DIR" \
		MCP_CONFIG_DST="$MCP_CONFIG_DST" \
		EXTENSION_DST="$EXTENSION_DST" \
		EXTENSION_NAMES="${EXTENSION_NAMES[*]}" \
		EXTENSIONS_DST="$EXTENSIONS_DST" \
		EXTENSION_BACKUP="$INSTALL_EXTENSION_BACKUP" \
		SKILLS_DST="$SKILLS_DST" \
		REFERENCES_DST="$REFERENCES_DST" \
		TEMPLATES_DST="$TEMPLATES_DST" \
		CAPABILITY_CONTRACT_SRC="$CAPABILITIES_SRC" \
		KERNEL_DST="$KERNEL_DST" \
		THEME_DST="$THEME_DST" \
		THEME_CACHED_DST="$THEME_CACHED_DST" \
		SKILLS="$skills_string" \
		python3 - <<'PY'
import json
import os
from pathlib import Path

skills = [name for name in os.environ['SKILLS'].split() if name]
import base64

extension_backups = {}
for item in os.environ['EXTENSION_BACKUP'].split():
    if '|' in item:
        name, encoded = item.split('|', 1)
        try:
            extension_backups[name] = base64.b64decode(encoded).decode()
        except Exception:
            continue
    elif '=' in item:  # legacy triplet output
        name, backup = item.split('=', 1)
        extension_backups[name] = backup
try:
    capability_contract = json.loads(Path(os.environ['CAPABILITY_CONTRACT_SRC']).read_text())
    if not isinstance(capability_contract, dict) or not isinstance(capability_contract.get('capabilities'), list):
        raise ValueError('invalid capability contract shape')
except Exception:
    # Keep manifests readable for source checkouts predating the capability contract.
    capability_contract = {'schema_version': 1, 'capabilities': []}

legacy_states = {
    'memoryAction': os.environ['MEMORY_ACTION'],
    'extensionAction': os.environ['EXTENSION_ACTION'],
    'extensionState': os.environ['EXTENSION_STATE'],
    'mcpAction': os.environ['MCP_ACTION'],
    'mcpState': os.environ['MCP_STATE'],
    'mcpAdapterAction': os.environ['MCP_ADAPTER_ACTION'],
    'mcpAdapterState': os.environ['MCP_ADAPTER_STATE'],
    'piObservationalMemoryAction': os.environ['PI_OBSERVATIONAL_MEMORY_ACTION'],
    'piObservationalMemoryState': os.environ['PI_OBSERVATIONAL_MEMORY_STATE'],
    'piUsageAction': os.environ['PI_USAGE_ACTION'],
    'piUsageState': os.environ['PI_USAGE_STATE'],
    'piAnthropicAuthAction': os.environ['PI_ANTHROPIC_AUTH_ACTION'],
    'piAnthropicAuthState': os.environ['PI_ANTHROPIC_AUTH_STATE'],
    'piIntercomAction': os.environ['PI_INTERCOM_ACTION'],
    'piIntercomState': os.environ['PI_INTERCOM_STATE'],
    'piAskUserQuestionAction': os.environ['PI_ASK_USER_QUESTION_ACTION'],
    'piAskUserQuestionState': os.environ['PI_ASK_USER_QUESTION_STATE'],
    'piTodoAction': os.environ['PI_TODO_ACTION'],
    'piTodoState': os.environ['PI_TODO_STATE'],
    'themeAction': os.environ['THEME_ACTION'],
    'themeState': os.environ['THEME_STATE'],
}
def capability_state(capability, value):
    # The legacy installer calls an active managed asset ready in the capability view.
    return 'ready' if value == 'active' else value

capability_states = {}
for capability in capability_contract.get('capabilities', []):
    if not isinstance(capability, dict) or not isinstance(capability.get('id'), str):
        continue
    install_state = capability.get('install_state', {})
    if not isinstance(install_state, dict):
        install_state = {}
    capability_states[capability['id']] = {
        'action': legacy_states.get(install_state.get('action'), 'unknown'),
        'state': capability_state(capability, legacy_states.get(install_state.get('state'), 'unknown')),
    }

manifest = {
    'suite': 'b-agentic',
    'runtime': os.environ['RUNTIME'],
    'installedAt': os.environ['TIMESTAMP'],
    'activationState': os.environ['ACTIVATION_STATE'],
    'capabilityContractVersion': capability_contract.get('schema_version', 1),
    'capabilities': {
        'contractVersion': capability_contract.get('schema_version', 1),
        'states': capability_states,
    },
    'memoryAction': os.environ['MEMORY_ACTION'],
    'extensionAction': os.environ['EXTENSION_ACTION'],
    'extensionState': os.environ['EXTENSION_STATE'],
    'mcpAction': os.environ['MCP_ACTION'],
    'mcpState': os.environ['MCP_STATE'],
    'mcpAdapterAction': os.environ['MCP_ADAPTER_ACTION'],
    'mcpAdapterState': os.environ['MCP_ADAPTER_STATE'],
    'piObservationalMemoryAction': os.environ['PI_OBSERVATIONAL_MEMORY_ACTION'],
    'piObservationalMemoryState': os.environ['PI_OBSERVATIONAL_MEMORY_STATE'],
    'piUsageAction': os.environ['PI_USAGE_ACTION'],
    'piUsageState': os.environ['PI_USAGE_STATE'],
    'piAnthropicAuthAction': os.environ['PI_ANTHROPIC_AUTH_ACTION'],
    'piAnthropicAuthState': os.environ['PI_ANTHROPIC_AUTH_STATE'],
    'piIntercomAction': os.environ['PI_INTERCOM_ACTION'],
    'piIntercomState': os.environ['PI_INTERCOM_STATE'],
    'piAskUserQuestionAction': os.environ['PI_ASK_USER_QUESTION_ACTION'],
    'piAskUserQuestionState': os.environ['PI_ASK_USER_QUESTION_STATE'],
    'piTodoAction': os.environ['PI_TODO_ACTION'],
    'piTodoState': os.environ['PI_TODO_STATE'],
    'themeAction': os.environ['THEME_ACTION'],
    'themeState': os.environ['THEME_STATE'],
    'paths': {
        'piAgentDir': os.environ['PI_AGENT_DIR'],
        'mcpConfig': os.environ['MCP_CONFIG_DST'],
        'permissionsExtension': os.environ['EXTENSION_DST'],
        'extensions': {
            name: str(Path(os.environ['EXTENSIONS_DST']) / name)
            for name in os.environ['EXTENSION_NAMES'].split()
        },
        'kernel': os.environ['KERNEL_DST'],
        'skills': os.environ['SKILLS_DST'],
        'references': os.environ['REFERENCES_DST'],
        'capabilityContract': str(Path(os.environ['REFERENCES_DST']) / 'capabilities.yaml'),
        'templates': os.environ['TEMPLATES_DST'],
        'theme': os.environ['THEME_DST'],
        'cachedTheme': os.environ['THEME_CACHED_DST'],
    },
    'skills': skills,
    'backups': {
        'agentsMd': os.environ['MEMORY_BACKUP'],
        'permissionsExtension': extension_backups.get('b-agentic-permissions.ts', 'none'),
        'extensions': extension_backups,
        'mcpConfig': os.environ['MCP_BACKUP'],
    },
}
Path(os.environ['MANIFEST_DST']).write_text(json.dumps(manifest, indent=2, sort_keys=True) + '\n')
PY
}

runtime_print_install_report() {
	local -a attention=()
	local status shell_status summary_label="Installed"
	local component_summary="core and required tooling"

	if installer_component_enabled mcp; then
		component_summary="$component_summary; MCP support"
	else
		component_summary="$component_summary; MCP support skipped"
	fi
	if installer_component_enabled pi-integrations; then
		component_summary="$component_summary; Pi integrations"
	else
		component_summary="$component_summary; Pi integrations skipped"
	fi
	if installer_component_enabled theme; then
		component_summary="$component_summary; Dracula theme"
	else
		component_summary="$component_summary; Dracula theme skipped"
	fi

	installer_summary_log "b-agentic install complete for Pi"
	installer_summary_log "Components: $component_summary"
	if dry_run_enabled; then
		summary_label="Planned"
	fi
	installer_summary_log "$summary_label: ${#INSTALL_SKILL_NAMES[@]} skills; kernel $INSTALL_MEMORY_ACTION; MCP $INSTALL_MCP_ACTION"
	if dry_run_enabled; then
		installer_summary_log "Manifest: not written (dry-run)"
	else
		installer_summary_log "Manifest: $MANIFEST_DST"
	fi

	if [ "$INSTALL_ACTIVATION_STATE" = "pending" ]; then
		attention+=("activation: review $KERNEL_SNAPSHOT_DST, then rerun with --replace-memory if desired")
	fi

	status="$(codegraph_readiness_status)"
	case "$status" in ready:*) ;; *) attention+=("codegraph: $status") ;; esac
	status="$(rtk_readiness_status)"
	case "$status" in ready:*) ;; *) attention+=("rtk: $status") ;; esac

	if installer_component_enabled mcp; then
		status="$(context7_readiness_status)"
		case "$status" in ready:*) ;; *) attention+=("context7: $status") ;; esac
		status="$(brave_search_readiness_status)"
		case "$status" in ready:*) ;; *) attention+=("brave-search: $status") ;; esac
		status="$(firecrawl_readiness_status)"
		case "$status" in ready:*) ;; *) attention+=("firecrawl: $status") ;; esac
		status="$(playwright_readiness_status)"
		case "$status" in ready:*) ;; *) attention+=("playwright: $status") ;; esac
		[ "$INSTALL_PI_MCP_ADAPTER_STATE" = "ready" ] || attention+=("mcp-adapter: install $PI_MCP_ADAPTER_PACKAGE with 'pi install $PI_MCP_ADAPTER_SPEC'")
	fi

	if installer_component_enabled pi-integrations; then
		[ "$INSTALL_PI_OBSERVATIONAL_MEMORY_STATE" = "ready" ] || attention+=("observational-memory: install $PI_OBSERVATIONAL_MEMORY_PACKAGE with 'pi install $PI_OBSERVATIONAL_MEMORY_SPEC'")
		[ "$INSTALL_PI_USAGE_STATE" = "ready" ] || attention+=("pi-usage: install $PI_USAGE_PACKAGE with 'pi install $PI_USAGE_SPEC'")
		[ "$INSTALL_PI_ANTHROPIC_AUTH_STATE" = "ready" ] || attention+=("anthropic-auth: install $PI_ANTHROPIC_AUTH_PACKAGE with 'pi install $PI_ANTHROPIC_AUTH_SPEC'")
		[ "$INSTALL_PI_INTERCOM_STATE" = "ready" ] || attention+=("pi-intercom: install $PI_INTERCOM_PACKAGE with 'pi install $PI_INTERCOM_SPEC'")
		[ "$INSTALL_PI_ASK_USER_QUESTION_STATE" = "ready" ] || attention+=("ask-user-question: install $PI_ASK_USER_QUESTION_PACKAGE with 'pi install $PI_ASK_USER_QUESTION_SPEC'")
		[ "$INSTALL_PI_TODO_STATE" = "ready" ] || attention+=("pi-todo: install $PI_TODO_PACKAGE with 'pi install $PI_TODO_SPEC'")
	fi

	shell_status="$(shell_tool_readiness_status)"
	case "$shell_status" in
	ready:*) ;;
	*) attention+=("shell tooling: $shell_status; hint: $(shell_tool_install_hint "$(detect_shell_tool_package_manager)")") ;;
	esac

	if [ "${#attention[@]}" -gt 0 ]; then
		installer_summary_log "Readiness:"
		installer_summary_log "Attention:"
		for status in "${attention[@]}"; do
			installer_summary_log "  $status"
		done
	else
		installer_summary_log "Readiness: ready"
	fi

	if dry_run_enabled; then
		installer_summary_log "Next: rerun without --dry-run to apply the plan; no manifest was written."
	elif [ "$INSTALL_ACTIVATION_STATE" = "pending" ]; then
		installer_summary_log "Next: review the activation snapshot; see $MANIFEST_DST for backups and installed paths."
	else
		installer_summary_log "Next: start a new Pi session; see $MANIFEST_DST for backups and installed paths."
	fi
}

runtime_uninstall_configs() {
	local mcp_config_path name extension_path snapshot original backup theme_path cached_theme_path is_owned
	mcp_config_path="$(manifest_path_value mcpConfig "$MCP_CONFIG_DST")"
	remove_merged_config "$mcp_config_path" "$TEMPLATES_DST/mcp.user.template.json" "mcp.json" "mcpConfig" "mcpAction"
	for name in "${EXTENSION_NAMES[@]}"; do
		extension_path="$(manifest_extension_path "$name" "$EXTENSIONS_DST/$name")"
		snapshot="$METADATA_DIR/extensions/$name"
		if [ -L "$extension_path" ]; then
			warn "preserving symlinked Pi extension: $extension_path"
		elif [ -f "$extension_path" ]; then
			if [ -f "$snapshot" ] && cmp -s "$extension_path" "$snapshot"; then
				original="$(manifest_backup_value "extension:$name" none)"
				[ "$original" = "none" ] && [ "$name" = "b-agentic-permissions.ts" ] && original="$(manifest_backup_value permissionsExtension none)"
				if [ "$original" = "none" ]; then
					run_cmd rm -f "$extension_path"
				elif [ -f "$original" ] && [ ! -L "$original" ] && [[ "$original" == "$METADATA_DIR/backups/"* ]]; then
					copy_file "$original" "$extension_path"
				else
					warn "preserving Pi extension because its original backup is unavailable: $extension_path"
				fi
			else
				warn "preserving modified Pi extension: $extension_path"
			fi
		fi
	 done

	theme_path="$(manifest_path_value theme "$THEME_DST")"
	cached_theme_path="$(manifest_path_value cachedTheme "$THEME_CACHED_DST")"
	if [ -L "$theme_path" ]; then
		is_owned="$(python3 - "$theme_path" "$cached_theme_path" <<'PY'
import os
import sys
from pathlib import Path

theme_dst = Path(sys.argv[1])
cached = Path(sys.argv[2])
try:
    target = Path(os.readlink(theme_dst))
    if not target.is_absolute():
        target = theme_dst.parent / target
    if target.resolve() == cached.resolve() or target == cached:
        print("yes")
    else:
        print("no")
except Exception:
    print("no")
PY
)"
		if [ "$is_owned" = "yes" ]; then
			run_cmd rm -f "$theme_path"
		else
			warn "preserving symlinked Pi theme: $theme_path"
		fi
	elif [ -e "$theme_path" ]; then
		warn "preserving modified Pi theme: $theme_path"
	fi
	# Intentionally leave all Pi packages installed.
}


pi_install() {
	runtime_install_common
}

pi_sync() {
	runtime_sync_common
}

pi_update() {
	set_install_stage_total 11
	run_stage "Updating Pi CLI" runtime_upgrade_cli || return $?
	run_stage "Installing Pi MCP adapter" maybe_install_pi_mcp_adapter || return $?
	run_stage "Installing observational memory" maybe_install_pi_observational_memory || return $?
	run_stage "Installing Pi usage" maybe_install_pi_usage || return $?
	run_stage "Installing Anthropic auth" maybe_install_pi_anthropic_auth || return $?
	run_stage "Installing Pi intercom" maybe_install_pi_intercom || return $?
	run_stage "Installing ask-user-question extension" maybe_install_pi_ask_user_question || return $?
	run_stage "Installing Pi todo" maybe_install_pi_todo || return $?
	run_stage "Syncing first-party extensions" install_permissions_extension >/dev/null || return $?
	run_stage "Updating Pi extensions" update_pi_extensions || return $?
	run_stage "Updating Dracula theme" install_dracula_theme
}

pi_uninstall() {
	runtime_uninstall_common
}
