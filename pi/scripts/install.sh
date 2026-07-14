# Sourced by install.sh — do not run directly.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
	echo "error: this script is sourced by install.sh" >&2
	exit 1
fi

readonly RUNTIME_UNINSTALL_LABEL="Pi personal config"
readonly RUNTIME_PRESERVE_LABEL="Pi"
readonly PI_AGENT_DIR="${B_AGENTIC_PI_AGENT_DIR:-$HOME/.pi/agent}"
readonly METADATA_DIR="$PI_AGENT_DIR/b-agentic"
readonly BACKUPS_DIR="$METADATA_DIR/backups"
readonly SKILLS_DST="$PI_AGENT_DIR/skills"
readonly KERNEL_DST="$PI_AGENT_DIR/AGENTS.md"
readonly KERNEL_SNAPSHOT_DST="$METADATA_DIR/AGENTS.md"
readonly REFERENCES_DST="$METADATA_DIR/references"
readonly TEMPLATES_DST="$METADATA_DIR/templates"
readonly MANIFEST_DST="$METADATA_DIR/install.json"
readonly MCP_CONFIG_DST="${B_AGENTIC_PI_MCP_JSON:-$PI_AGENT_DIR/mcp.json}"
readonly EXTENSIONS_DST="$PI_AGENT_DIR/extensions"
readonly EXTENSION_DST="$EXTENSIONS_DST/b-agentic-permissions.ts"
readonly EXTENSION_SNAPSHOT_DST="$METADATA_DIR/extensions/b-agentic-permissions.ts"
readonly EXTENSION_SRC="$SOURCE_DIR/pi/extensions/b-agentic-permissions.ts"
readonly PI_MCP_ADAPTER_SPEC="npm:pi-mcp-adapter"
readonly PI_MCP_ADAPTER_PACKAGE="pi-mcp-adapter"
readonly PI_LENS_SPEC="npm:pi-lens"
readonly PI_LENS_PACKAGE="pi-lens"
readonly PI_OBSERVATIONAL_MEMORY_SPEC="npm:pi-observational-memory"
readonly PI_OBSERVATIONAL_MEMORY_PACKAGE="pi-observational-memory"
readonly MCP_ROOT_KEY="mcpServers"
readonly MCP_PLACEHOLDER_STYLE="claude"
readonly MCP_CONTEXT7_SECTION="headers"
readonly MCP_BRAVE_SECTION="env"
readonly MCP_FIRECRAWL_SECTION="env"
readonly MCP_BACKUP_KEY="mcpConfig"
readonly EXTENSION_BACKUP_KEY="permissionsExtension"

CONTEXT7_API_KEY_INPUT=""
BRAVE_API_KEY_INPUT=""
FIRECRAWL_API_KEY_INPUT=""
FIRECRAWL_API_URL_INPUT=""
INSTALL_EXTENSION_ACTION="skip"
INSTALL_EXTENSION_STATE="none"
INSTALL_EXTENSION_BACKUP="none"
INSTALL_PI_MCP_ADAPTER_ACTION="skip"
INSTALL_PI_MCP_ADAPTER_STATE="missing"
INSTALL_PI_LENS_ACTION="skip"
INSTALL_PI_LENS_STATE="missing"
INSTALL_PI_OBSERVATIONAL_MEMORY_ACTION="skip"
INSTALL_PI_OBSERVATIONAL_MEMORY_STATE="missing"

runtime_warn_missing_cli() {
	command -v pi >/dev/null 2>&1 || warn "Pi CLI 'pi' not found; files will still be installed for Pi to discover later."
	command -v codegraph >/dev/null 2>&1 || warn "codegraph CLI not found; CodeGraph MCP will not start until CodeGraph is installed."
	command -v pnpm >/dev/null 2>&1 || warn "pnpm not found; MCP servers that use 'pnpm dlx' (Brave, Firecrawl, Playwright) will not start until pnpm is installed."
	if command -v pi >/dev/null 2>&1 && ! pi_mcp_adapter_installed; then
		warn "pi-mcp-adapter not installed; MCP servers will not load until the adapter is installed."
	fi
	if command -v pi >/dev/null 2>&1 && ! pi_lens_installed; then
		warn "pi-lens not installed; live diagnostics and structural analysis are unavailable."
	fi
	if command -v pi >/dev/null 2>&1 && ! pi_observational_memory_installed; then
		warn "pi-observational-memory not installed; long-session compaction continuity is unavailable."
	fi
}

runtime_cli_installed() {
	command -v pi >/dev/null 2>&1
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
			warn "Pi CLI install/upgrade failed; continuing"
		fi
	elif curl -fsSL https://pi.dev/install.sh | sh; then
		log "Pi CLI install/upgrade completed"
	else
		warn "Pi CLI install/upgrade failed; continuing"
	fi
	return 0
}

pi_package_installed() {
	local package="$1"
	if ! command -v pi >/dev/null 2>&1; then
		return 1
	fi
	local listing
	# Bind to current HOME so sandbox / alternate-home installs do not
	# report a global package install as ready for this target.
	listing="$(
		HOME="${HOME}" \
			PI_CODING_AGENT_DIR="${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}" \
			pi list 2>/dev/null || true
	)"
	printf '%s\n' "$listing" | grep -Eq "${package}(@| )|npm:${package}"
}

pi_mcp_adapter_installed() {
	pi_package_installed "$PI_MCP_ADAPTER_PACKAGE"
}

pi_lens_installed() {
	pi_package_installed "$PI_LENS_PACKAGE"
}

pi_observational_memory_installed() {
	pi_package_installed "$PI_OBSERVATIONAL_MEMORY_PACKAGE"
}

install_pi_mcp_adapter_enabled() {
	local value="${B_AGENTIC_INSTALL_PI_MCP_ADAPTER:-auto}"
	case "$value" in
	n | N | no | NO | No | false | FALSE | 0) return 1 ;;
	y | Y | yes | YES | Yes | true | TRUE | 1) return 0 ;;
	auto | AUTO | Auto)
		if pi_mcp_adapter_installed; then
			return 1
		fi
		if [ -r /dev/tty ] && [ -w /dev/tty ]; then
			prompt_yes_no "Install Pi MCP adapter ($PI_MCP_ADAPTER_PACKAGE)? [y/N]" N
			return $?
		fi
		return 1
		;;
	*) die "invalid B_AGENTIC_INSTALL_PI_MCP_ADAPTER value: $value" ;;
	esac
}

maybe_install_pi_mcp_adapter() {
	if pi_mcp_adapter_installed; then
		INSTALL_PI_MCP_ADAPTER_ACTION="present"
		INSTALL_PI_MCP_ADAPTER_STATE="ready"
		log "Pi MCP adapter $PI_MCP_ADAPTER_PACKAGE already installed"
		return 0
	fi

	if ! command -v pi >/dev/null 2>&1; then
		INSTALL_PI_MCP_ADAPTER_ACTION="skip"
		INSTALL_PI_MCP_ADAPTER_STATE="missing-cli"
		warn "Pi CLI missing; cannot install $PI_MCP_ADAPTER_PACKAGE"
		return 0
	fi

	if ! install_pi_mcp_adapter_enabled; then
		INSTALL_PI_MCP_ADAPTER_ACTION="skip"
		INSTALL_PI_MCP_ADAPTER_STATE="missing"
		warn "Skipping $PI_MCP_ADAPTER_PACKAGE install; set B_AGENTIC_INSTALL_PI_MCP_ADAPTER=Y or accept the interactive prompt"
		return 0
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
		warn "Failed to install $PI_MCP_ADAPTER_PACKAGE; MCP will remain degraded"
	fi
}

install_pi_lens_enabled() {
	local value="${B_AGENTIC_INSTALL_PI_LENS:-auto}"
	case "$value" in
	n | N | no | NO | No | false | FALSE | 0) return 1 ;;
	y | Y | yes | YES | Yes | true | TRUE | 1) return 0 ;;
	auto | AUTO | Auto)
		if pi_lens_installed; then
			return 1
		fi
		if [ -r /dev/tty ] && [ -w /dev/tty ]; then
			prompt_yes_no "Install Pi Lens ($PI_LENS_PACKAGE)? [y/N]" N
			return $?
		fi
		return 1
		;;
	*) die "invalid B_AGENTIC_INSTALL_PI_LENS value: $value" ;;
	esac
}

maybe_install_pi_lens() {
	if pi_lens_installed; then
		INSTALL_PI_LENS_ACTION="present"
		INSTALL_PI_LENS_STATE="ready"
		log "Pi Lens $PI_LENS_PACKAGE already installed"
		return 0
	fi

	if ! command -v pi >/dev/null 2>&1; then
		INSTALL_PI_LENS_ACTION="skip"
		INSTALL_PI_LENS_STATE="missing-cli"
		warn "Pi CLI missing; cannot install $PI_LENS_PACKAGE"
		return 0
	fi

	if ! install_pi_lens_enabled; then
		INSTALL_PI_LENS_ACTION="skip"
		INSTALL_PI_LENS_STATE="missing"
		warn "Skipping $PI_LENS_PACKAGE install; set B_AGENTIC_INSTALL_PI_LENS=Y or accept the interactive prompt"
		return 0
	fi

	if dry_run_enabled; then
		printf '[dry-run] pi install %s\n' "$PI_LENS_SPEC" >&2
		INSTALL_PI_LENS_ACTION="install"
		INSTALL_PI_LENS_STATE="dry-run"
		return 0
	fi

	log "Installing $PI_LENS_PACKAGE"
	if pi install "$PI_LENS_SPEC"; then
		INSTALL_PI_LENS_ACTION="install"
		INSTALL_PI_LENS_STATE="ready"
		log "Installed $PI_LENS_PACKAGE"
	else
		INSTALL_PI_LENS_ACTION="failed"
		INSTALL_PI_LENS_STATE="missing"
		warn "Failed to install $PI_LENS_PACKAGE; live diagnostics and structural analysis remain unavailable"
	fi
}

install_pi_observational_memory_enabled() {
	local value="${B_AGENTIC_INSTALL_PI_OBSERVATIONAL_MEMORY:-auto}"
	case "$value" in
	n | N | no | NO | No | false | FALSE | 0) return 1 ;;
	y | Y | yes | YES | Yes | true | TRUE | 1) return 0 ;;
	auto | AUTO | Auto)
		if pi_observational_memory_installed; then
			return 1
		fi
		if [ -r /dev/tty ] && [ -w /dev/tty ]; then
			prompt_yes_no "Install Pi Observational Memory ($PI_OBSERVATIONAL_MEMORY_PACKAGE)? [y/N]" N
			return $?
		fi
		return 1
		;;
	*) die "invalid B_AGENTIC_INSTALL_PI_OBSERVATIONAL_MEMORY value: $value" ;;
	esac
}

maybe_install_pi_observational_memory() {
	if pi_observational_memory_installed; then
		INSTALL_PI_OBSERVATIONAL_MEMORY_ACTION="present"
		INSTALL_PI_OBSERVATIONAL_MEMORY_STATE="ready"
		log "Pi Observational Memory $PI_OBSERVATIONAL_MEMORY_PACKAGE already installed"
		return 0
	fi

	if ! command -v pi >/dev/null 2>&1; then
		INSTALL_PI_OBSERVATIONAL_MEMORY_ACTION="skip"
		INSTALL_PI_OBSERVATIONAL_MEMORY_STATE="missing-cli"
		warn "Pi CLI missing; cannot install $PI_OBSERVATIONAL_MEMORY_PACKAGE"
		return 0
	fi

	if ! install_pi_observational_memory_enabled; then
		INSTALL_PI_OBSERVATIONAL_MEMORY_ACTION="skip"
		INSTALL_PI_OBSERVATIONAL_MEMORY_STATE="missing"
		warn "Skipping $PI_OBSERVATIONAL_MEMORY_PACKAGE install; set B_AGENTIC_INSTALL_PI_OBSERVATIONAL_MEMORY=Y or accept the interactive prompt"
		return 0
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
		warn "Failed to install $PI_OBSERVATIONAL_MEMORY_PACKAGE; long-session compaction continuity remains unavailable"
	fi
}

runtime_install_config_stage_count() { # permission extension + MCP merge + prompted keys
	printf '3'
}

install_permissions_extension() {
	if [ ! -f "$EXTENSION_SRC" ]; then
		die "missing Pi permission extension source: $EXTENSION_SRC"
	fi

	if dry_run_enabled; then
		printf '[dry-run] install extension %s -> %s\n' "$EXTENSION_SRC" "$EXTENSION_DST" >&2
		printf 'write\nactive\nnone'
		return 0
	fi

	ensure_dir "$EXTENSIONS_DST"
	ensure_dir "$(dirname "$EXTENSION_SNAPSHOT_DST")"
	copy_file "$EXTENSION_SRC" "$EXTENSION_SNAPSHOT_DST"

	if [ -f "$EXTENSION_DST" ]; then
		if cmp -s "$EXTENSION_SRC" "$EXTENSION_DST"; then
			printf 'skip\nactive\nnone'
			return 0
		fi
		local backup
		backup="$(backup_file "$EXTENSION_DST")"
		copy_file "$EXTENSION_SRC" "$EXTENSION_DST"
		printf 'replace\nactive\n%s' "${backup:-none}"
		return 0
	fi

	copy_file "$EXTENSION_SRC" "$EXTENSION_DST"
	printf 'write\nactive\nnone'
}

runtime_install_extra_assets() {
	:
}

runtime_install_configs() {
	maybe_install_pi_mcp_adapter
	maybe_install_pi_lens
	maybe_install_pi_observational_memory
	run_install_triplet_stage "Installing Pi permission extension" install_permissions_extension "skip" "none" "none" \
		INSTALL_EXTENSION_ACTION INSTALL_EXTENSION_STATE INSTALL_EXTENSION_BACKUP
	run_install_triplet_stage "Merging MCP config" install_mcp_config "skip" "none" "none" \
		INSTALL_MCP_ACTION INSTALL_MCP_STATE INSTALL_MCP_BACKUP
	apply_prompted_mcp_keys_stage INSTALL_MCP_ACTION INSTALL_MCP_BACKUP
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
		PI_LENS_ACTION="$INSTALL_PI_LENS_ACTION" \
		PI_LENS_STATE="$INSTALL_PI_LENS_STATE" \
		PI_OBSERVATIONAL_MEMORY_ACTION="$INSTALL_PI_OBSERVATIONAL_MEMORY_ACTION" \
		PI_OBSERVATIONAL_MEMORY_STATE="$INSTALL_PI_OBSERVATIONAL_MEMORY_STATE" \
		PI_AGENT_DIR="$PI_AGENT_DIR" \
		MCP_CONFIG_DST="$MCP_CONFIG_DST" \
		EXTENSION_DST="$EXTENSION_DST" \
		SKILLS_DST="$SKILLS_DST" \
		REFERENCES_DST="$REFERENCES_DST" \
		TEMPLATES_DST="$TEMPLATES_DST" \
		KERNEL_DST="$KERNEL_DST" \
		SKILLS="$skills_string" \
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
    'extensionAction': os.environ['EXTENSION_ACTION'],
    'extensionState': os.environ['EXTENSION_STATE'],
    'mcpAction': os.environ['MCP_ACTION'],
    'mcpState': os.environ['MCP_STATE'],
    'mcpAdapterAction': os.environ['MCP_ADAPTER_ACTION'],
    'mcpAdapterState': os.environ['MCP_ADAPTER_STATE'],
    'piLensAction': os.environ['PI_LENS_ACTION'],
    'piLensState': os.environ['PI_LENS_STATE'],
    'piObservationalMemoryAction': os.environ['PI_OBSERVATIONAL_MEMORY_ACTION'],
    'piObservationalMemoryState': os.environ['PI_OBSERVATIONAL_MEMORY_STATE'],
    'paths': {
        'piAgentDir': os.environ['PI_AGENT_DIR'],
        'mcpConfig': os.environ['MCP_CONFIG_DST'],
        'permissionsExtension': os.environ['EXTENSION_DST'],
        'kernel': os.environ['KERNEL_DST'],
        'skills': os.environ['SKILLS_DST'],
        'references': os.environ['REFERENCES_DST'],
        'templates': os.environ['TEMPLATES_DST'],
    },
    'skills': skills,
    'backups': {
        'agentsMd': os.environ['MEMORY_BACKUP'],
        'permissionsExtension': os.environ['EXTENSION_BACKUP'],
        'mcpConfig': os.environ['MCP_BACKUP'],
    },
}
Path(os.environ['MANIFEST_DST']).write_text(json.dumps(manifest, indent=2, sort_keys=True) + '\n')
PY
}

runtime_print_install_report() {
	print_install_report_header "Pi"
	report_section "Summary"
	report_item "activation" "$INSTALL_ACTIVATION_STATE"
	report_item "skills" "${#INSTALL_SKILL_NAMES[@]} synced -> $SKILLS_DST"
	report_item "kernel" "$INSTALL_MEMORY_ACTION -> $KERNEL_DST"
	report_item "permissions" "$INSTALL_EXTENSION_ACTION -> $EXTENSION_DST"
	report_item "mcp" "$INSTALL_MCP_ACTION -> $MCP_CONFIG_DST"
	report_item "mcp-adapter" "$INSTALL_PI_MCP_ADAPTER_ACTION ($INSTALL_PI_MCP_ADAPTER_STATE)"
	report_item "pi-lens" "$INSTALL_PI_LENS_ACTION ($INSTALL_PI_LENS_STATE)"
	report_item "pi-observational-memory" "$INSTALL_PI_OBSERVATIONAL_MEMORY_ACTION ($INSTALL_PI_OBSERVATIONAL_MEMORY_STATE)"
	report_item "references" "sync -> $REFERENCES_DST"
	report_item "templates" "sync -> $TEMPLATES_DST"
	report_item "manifest" "write -> $MANIFEST_DST"
	report_section "Backups"
	report_item "kernel" "$INSTALL_MEMORY_BACKUP"
	report_item "permissions" "$INSTALL_EXTENSION_BACKUP"
	report_item "mcp" "$INSTALL_MCP_BACKUP"
	print_install_report_readiness
	print_shell_tool_recommendations
	if [ "$INSTALL_PI_MCP_ADAPTER_STATE" != "ready" ]; then
		report_section "MCP adapter"
		report_item "status" "degraded: install $PI_MCP_ADAPTER_PACKAGE with 'pi install $PI_MCP_ADAPTER_SPEC' or B_AGENTIC_INSTALL_PI_MCP_ADAPTER=Y"
	fi
	if [ "$INSTALL_PI_LENS_STATE" != "ready" ]; then
		report_section "Pi Lens"
		report_item "status" "optional: install $PI_LENS_PACKAGE with 'pi install $PI_LENS_SPEC' or B_AGENTIC_INSTALL_PI_LENS=Y"
	fi
	if [ "$INSTALL_PI_OBSERVATIONAL_MEMORY_STATE" != "ready" ]; then
		report_section "Pi Observational Memory"
		report_item "status" "optional: install $PI_OBSERVATIONAL_MEMORY_PACKAGE with 'pi install $PI_OBSERVATIONAL_MEMORY_SPEC' or B_AGENTIC_INSTALL_PI_OBSERVATIONAL_MEMORY=Y"
	fi
	print_install_report_next_steps "Pi"
}

runtime_uninstall_configs() {
	local mcp_config_path extension_path
	mcp_config_path="$(manifest_path_value mcpConfig "$MCP_CONFIG_DST")"
	extension_path="$(manifest_path_value permissionsExtension "$EXTENSION_DST")"
	remove_merged_config "$mcp_config_path" "$TEMPLATES_DST/mcp.user.template.json" "mcp.json" "mcpConfig" "mcpAction"
	if [ -f "$extension_path" ]; then
		local snapshot="$METADATA_DIR/extensions/b-agentic-permissions.ts"
		if [ -f "$snapshot" ] && cmp -s "$extension_path" "$snapshot"; then
			run_cmd rm -f "$extension_path"
		else
			warn "preserving modified Pi permission extension: $extension_path"
		fi
	fi
	# Intentionally leave pi-mcp-adapter, pi-lens, and pi-observational-memory packages installed.
}

runtime_uninstall_extra_assets() { :; }

pi_install() {
	runtime_install_common
}

pi_uninstall() {
	runtime_uninstall_common
}
