#!/usr/bin/env bash
# B_AGENTIC_INSTALLER
# install.sh - Bootstrap or update b-agentic from a checksum-verified release
# tarball. The piped entrypoint is only a bootstrap: it downloads the release
# bundle, verifies its SHA-256 checksum and archive layout, and re-executes
# every state change from inside the verified bundle.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/dhoaibao/b-agentic/main/install.sh | bash
#   curl -fsSL https://raw.githubusercontent.com/dhoaibao/b-agentic/main/install.sh | bash -s -- --dry-run
#   curl -fsSL https://raw.githubusercontent.com/dhoaibao/b-agentic/main/install.sh | bash -s -- --uninstall
#   curl -fsSL https://raw.githubusercontent.com/dhoaibao/b-agentic/main/install.sh | bash -s -- --ref=vYYYY.MM.DD
#   curl -fsSL https://raw.githubusercontent.com/dhoaibao/b-agentic/main/install.sh | bash -s -- --agent pi
#   ~/.b-agentic/install.sh --sync
#   ~/.b-agentic/install.sh --update

set -euo pipefail
# Variables shared with the sourced installer core are intentionally defined
# here even when ShellCheck analyzes this entrypoint in isolation.

readonly REPO_WEB_BASE="https://github.com/dhoaibao/b-agentic"
readonly RELEASE_URL_LATEST="$REPO_WEB_BASE/releases/latest/download/b-agentic.tar.gz"
readonly CHECKSUM_URL_LATEST="$REPO_WEB_BASE/releases/latest/download/b-agentic.tar.gz.sha256"
readonly LOCAL_REPO="${B_AGENTIC_DIR:-$HOME/.b-agentic}"
REF="${B_AGENTIC_REF:-}"
TIMESTAMP="$(date +%Y%m%d%H%M%S)"
# shellcheck disable=SC2034
readonly TIMESTAMP

# Top-level payload paths the verified release bundle owns inside $LOCAL_REPO.
# sync_source() replaces exactly these entries and nothing else; everything
# beside them in $LOCAL_REPO is user-owned and is never touched.
MANAGED_PAYLOAD_ENTRIES=(
	"install.sh"
	"VERSION"
	"skills"
	"references"
	"adapters/pi/manifest.yaml"
	"adapters/pi/configs"
	"adapters/pi/extensions"
	"adapters/pi/packages"
	"adapters/pi/scripts"
	"tooling/install/common.sh"
	"tooling/install/json_cleanup.py"
	"tooling/install/jsonc.py"
	"tooling/install/manifest_uninstall.py"
)

SOURCE_DIR_EXPLICIT=""
VERIFIED_PAYLOAD=""
DOWNLOAD_TMP=""
SYNC_STAGE_DIR=""
SYNC_BACKUP_DIR=""
SYNC_MIGRATED=0
SYNC_MUTATED=0
SYNC_COPIED=0
SYNC_ROLLBACK_NEEDED=0

DRY_RUN_VALUE="${B_AGENTIC_DRY_RUN:-N}"
REPLACE_MEMORY_VALUE="${B_AGENTIC_REPLACE_MEMORY:-}"
UNINSTALL_VALUE="${B_AGENTIC_UNINSTALL:-N}"
PROMPT_API_KEYS_VALUE="${B_AGENTIC_PROMPT_API_KEYS:-auto}"
readonly PI_NAME="Pi"
# Agent adapter selection: only adapters whose manifest marks them shipped may
# install; verified-but-deferred hosts stay explicit non-goals (docs/hosts.md).
AGENT="${B_AGENTIC_AGENT:-pi}"
# Bundled dependencies are mandatory and are installed without prompts.
OPERATION="install"

SOURCE_DIR="$LOCAL_REPO"
SKILLS_SRC="$SOURCE_DIR/skills"
REFERENCES_SRC="$SOURCE_DIR/references"
TEMPLATES_SRC="$SOURCE_DIR/adapters/pi/configs"
KERNEL_SRC="$SOURCE_DIR/references/kernel.template.md"
UI_ENABLED=0
UI_SUPPRESS_LOGS=0
UI_STAGE_CURRENT=0
UI_STAGE_TOTAL=0
UI_STAGE_ACTIVE=0
UI_STAGE_LABEL=""
UI_COMPONENT_CURSOR=2
B_AGENTIC_COMPONENT_MCP=Y
B_AGENTIC_COMPONENT_PI_INTEGRATIONS=Y
B_AGENTIC_COMPONENT_THEME=Y
readonly UI_STAGE_BAR_WIDTH=20
readonly UI_STAGE_LABEL_WIDTH=52
readonly UI_STAGE_LINE_WIDTH=82
readonly UI_COMPONENT_COUNT=5
# shellcheck disable=SC2034
INSTALL_PI_CLI_DECISION=""

ui_init() {
	if [ -t 1 ] && [ "${TERM:-}" != "dumb" ]; then
		UI_ENABLED=1
	else
		UI_ENABLED=0
	fi
}

ui_tty_enabled() {
	[ "${UI_ENABLED:-0}" -eq 1 ] && [ -t 1 ] && [ "${TERM:-}" != "dumb" ]
}

component_enabled() {
	local component="$1" value=""
	case "$component" in
	mcp) value="${B_AGENTIC_COMPONENT_MCP:-Y}" ;;
	pi-integrations) value="${B_AGENTIC_COMPONENT_PI_INTEGRATIONS:-Y}" ;;
	theme) value="${B_AGENTIC_COMPONENT_THEME:-Y}" ;;
	*) return 1 ;;
	esac
	case "$value" in
	n | N | no | NO | No | false | FALSE | 0) return 1 ;;
	*) return 0 ;;
	esac
}

ui_component_enabled_at() {
	case "$1" in
	0 | 1) return 0 ;;
	2) component_enabled mcp ;;
	3) component_enabled pi-integrations ;;
	4) component_enabled theme ;;
	*) return 1 ;;
	esac
}

ui_component_toggle() {
	case "$1" in
	2)
		if component_enabled mcp; then B_AGENTIC_COMPONENT_MCP=N; else B_AGENTIC_COMPONENT_MCP=Y; fi
		;;
	3)
		if component_enabled pi-integrations; then B_AGENTIC_COMPONENT_PI_INTEGRATIONS=N; else B_AGENTIC_COMPONENT_PI_INTEGRATIONS=Y; fi
		;;
	4)
		if component_enabled theme; then B_AGENTIC_COMPONENT_THEME=N; else B_AGENTIC_COMPONENT_THEME=Y; fi
		;;
	esac
}

ui_component_move() {
	local direction="$1"
	local next=$((UI_COMPONENT_CURSOR + direction))
	[ "$next" -lt 2 ] && next=$((UI_COMPONENT_COUNT - 1))
	[ "$next" -ge "$UI_COMPONENT_COUNT" ] && next=2
	UI_COMPONENT_CURSOR="$next"
}

ui_component_draw() {
	local index marker cursor selected_separator=""
	{
		printf '\033[2J\033[H'
		printf 'b-agentic installer\n\n'
		printf 'Select optional components. Required items are always installed.\n'
		printf 'Use Up/Down to move, Space to toggle, Enter to continue, Esc to cancel.\n\n'
		for index in 0 1 2 3 4; do
			marker=' '
			ui_component_enabled_at "$index" && marker='x'
			cursor=' '
			[ "$UI_COMPONENT_CURSOR" -eq "$index" ] && cursor='>'
			case "$index" in
			0) printf '%s [%s] Pi and b-agentic core files (required)\n' "$cursor" "$marker" ;;
			1) printf '%s [%s] RTK, CodeGraph, and Bun (required)\n' "$cursor" "$marker" ;;
			2) printf '%s [%s] MCP support (adapter, config, and API keys)\n' "$cursor" "$marker" ;;
			3) printf '%s [%s] Pi integrations (memory, usage, auth, prompts, and todo)\n' "$cursor" "$marker" ;;
			4) printf '%s [%s] Dracula theme\n' "$cursor" "$marker" ;;
			esac
		done
		printf '\nSelected optional groups: '
		for index in 2 3 4; do
			if ui_component_enabled_at "$index"; then
				[ -n "$selected_separator" ] && printf '%s' "$selected_separator"
				case "$index" in
				2) printf 'MCP support' ;;
				3) printf 'Pi integrations' ;;
				4) printf 'Dracula theme' ;;
				esac
				selected_separator=', '
			fi
		done
		[ -n "$selected_separator" ] || printf 'none'
		printf '\n'
	} > /dev/tty
}

# macOS ships bash 3.2, which rejects fractional `read -t` values with
# "invalid timeout specification". Fall back to a whole-second escape window so
# arrow-key sequences are never misread as a bare Escape (cancel) there.
ui_component_escape_timeout() {
	local major="${1:-${BASH_VERSINFO[0]:-0}}"
	case "$major" in
	'' | *[!0-9]*) printf '1' ;;
	*)
		if [ "$major" -ge 4 ]; then
			printf '0.1'
		else
			printf '1'
		fi
		;;
	esac
}

ui_component_read_key() {
	local key="" sequence="" escape_timeout=""
	IFS= read -r -s -n 1 key < /dev/tty || return 1
	if [ -z "$key" ]; then
		printf 'enter'
		return 0
	fi
	case "$key" in
	' ')
		printf 'toggle'
		;;
	$'\033')
		escape_timeout="$(ui_component_escape_timeout)"
		if ! IFS= read -r -s -n 1 -t "$escape_timeout" sequence < /dev/tty; then
			printf 'escape'
			return 0
		fi
		if [ "$sequence" != '[' ]; then
			printf 'escape'
			return 0
		fi
		IFS= read -r -s -n 1 sequence < /dev/tty || return 1
		case "$sequence" in
		A) printf 'up' ;;
		B) printf 'down' ;;
		C) printf 'right' ;;
		D) printf 'left' ;;
		*) printf 'noop' ;;
		esac
		;;
	*)
		printf 'noop'
		;;
	esac
}

ui_component_close() {
	ui_tty_enabled || return 0
	printf '\033[2J\033[H' > /dev/tty
}

ui_component_picker() {
	[ "$OPERATION" = "install" ] || return 0
	uninstall_enabled && return 0
	ui_tty_enabled || return 0
	[ -r /dev/tty ] && [ -w /dev/tty ] || return 0

	UI_COMPONENT_CURSOR=2
	while :; do
		ui_component_draw || return 1
		local key=""
		key="$(ui_component_read_key)" || {
			ui_component_close
			return 1
		}
		case "$key" in
		up) ui_component_move -1 ;;
		down) ui_component_move 1 ;;
		toggle) ui_component_toggle "$UI_COMPONENT_CURSOR" ;;
		enter)
			ui_component_close
			{
				printf 'Selected components:\n'
				printf '  Pi and b-agentic core files\n'
				printf '  RTK, CodeGraph, and Bun\n'
				component_enabled mcp && printf '  MCP support\n'
				component_enabled pi-integrations && printf '  Pi integrations\n'
				component_enabled theme && printf '  Dracula theme\n'
				printf '\n'
			} > /dev/tty
			return 0
			;;
		escape)
			ui_component_close
			printf 'Installation cancelled.\n' > /dev/tty
			return 130
			;;
		esac
	done
}

ui_clear_stage() {
	ui_tty_enabled || return 0
	printf '\r%*s\r' "$UI_STAGE_LINE_WIDTH" ''
}

ui_render_stage() {
	ui_tty_enabled || return 0
	local current="$1" total="$2" label="$3" state="${4:-running}"
	local filled=0 bar="" i
	if [ "$total" -gt 0 ]; then
		filled=$(((current - 1) * UI_STAGE_BAR_WIDTH / total))
	fi
	[ "$filled" -lt 0 ] && filled=0
	[ "$filled" -gt "$UI_STAGE_BAR_WIDTH" ] && filled="$UI_STAGE_BAR_WIDTH"
	if [ "$state" = "done" ]; then
		filled="$UI_STAGE_BAR_WIDTH"
	fi
	for ((i = 0; i < filled; i++)); do bar+='='; done
	for ((i = filled; i < UI_STAGE_BAR_WIDTH; i++)); do bar+='-'; done
	case "$state" in
	failed) bar="!!!!!!!!!!!!!!!!!!!!" ;;
	done) bar="====================" ;;
	esac
	if [ "${#label}" -gt "$UI_STAGE_LABEL_WIDTH" ]; then
		label="${label:0:UI_STAGE_LABEL_WIDTH-3}..."
	fi
	printf -v label '%-*s' "$UI_STAGE_LABEL_WIDTH" "$label"
	if [ "$total" -gt 0 ]; then
		printf '\r[%s/%s] [%s] %s' "$current" "$total" "$bar" "$label"
	else
		printf '\r[%s] [%s] %s' "$current" "$bar" "$label"
	fi
}

ui_set_stage_total() {
	UI_STAGE_CURRENT=0
	UI_STAGE_TOTAL="${1:-0}"
	if ui_tty_enabled && [ "$UI_STAGE_ACTIVE" -eq 1 ]; then
		ui_clear_stage
		UI_STAGE_ACTIVE=0
	fi
}

ui_stage_start() {
	local label="$1"
	UI_STAGE_CURRENT=$((UI_STAGE_CURRENT + 1))
	UI_STAGE_LABEL="$label"
	UI_STAGE_ACTIVE=1
	if ui_tty_enabled; then
		ui_render_stage "$UI_STAGE_CURRENT" "$UI_STAGE_TOTAL" "$label"
	elif [ "$UI_STAGE_TOTAL" -gt 0 ]; then
		printf '[%s/%s] %s\n' "$UI_STAGE_CURRENT" "$UI_STAGE_TOTAL" "$label"
	else
		printf '[%s] %s\n' "$UI_STAGE_CURRENT" "$label"
	fi
}

ui_stage_finish() {
	local rc="${1:-0}"
	if [ "$UI_STAGE_ACTIVE" -eq 1 ] && ui_tty_enabled; then
		ui_clear_stage
		if [ "$UI_STAGE_TOTAL" -gt 0 ]; then
			if [ "$rc" -eq 0 ]; then
				printf '[%s/%s] %s\n' "$UI_STAGE_CURRENT" "$UI_STAGE_TOTAL" "$UI_STAGE_LABEL"
			else
				printf '[%s/%s] failed: %s\n' "$UI_STAGE_CURRENT" "$UI_STAGE_TOTAL" "$UI_STAGE_LABEL"
			fi
		else
			if [ "$rc" -eq 0 ]; then
				printf '[%s] %s\n' "$UI_STAGE_CURRENT" "$UI_STAGE_LABEL"
			else
				printf '[%s] failed: %s\n' "$UI_STAGE_CURRENT" "$UI_STAGE_LABEL"
			fi
		fi
	fi
	UI_STAGE_ACTIVE=0
	UI_STAGE_LABEL=""
	return "$rc"
}

ui_pause_stage() {
	ui_tty_enabled || return 0
	[ "$UI_STAGE_ACTIVE" -eq 1 ] || return 0
	ui_clear_stage
}

ui_resume_stage() {
	ui_tty_enabled || return 0
	[ "$UI_STAGE_ACTIVE" -eq 1 ] || return 0
	ui_render_stage "$UI_STAGE_CURRENT" "$UI_STAGE_TOTAL" "$UI_STAGE_LABEL"
}

log() {
	[ "${UI_SUPPRESS_LOGS:-0}" -eq 1 ] && return 0
	printf '%s\n' "$*"
}

summary_log() {
	ui_pause_stage
	printf '%s\n' "$*"
	ui_resume_stage
}

warn() {
	ui_pause_stage
	printf 'warning: %s\n' "$*" >&2
	ui_resume_stage
}

die() {
	ui_pause_stage
	printf 'error: %s\n' "$*" >&2
	exit 1
}

run_ui_stage() {
	local label="$1"
	shift
	local rc=0 previous_suppress="${UI_SUPPRESS_LOGS:-0}"

	ui_stage_start "$label"
	UI_SUPPRESS_LOGS=1
	if "$@"; then
		rc=0
	else
		rc=$?
	fi
	UI_SUPPRESS_LOGS="$previous_suppress"
	ui_stage_finish "$rc"
	return "$rc"
}

cleanup() {
	if [ -n "${DOWNLOAD_TMP:-}" ] && [ -d "$DOWNLOAD_TMP" ]; then
		rm -rf "$DOWNLOAD_TMP"
	fi
}

trap cleanup EXIT

sha256() {
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum "$1" | awk '{print $1}'
		return
	fi
	if command -v shasum >/dev/null 2>&1; then
		shasum -a 256 "$1" | awk '{print $1}'
		return
	fi
	die "sha256sum or shasum is required for checksum verification"
}

fetch_url() {
	local url="$1" dest="$2" hint="${3:-}"
	require_bin curl
	curl -fsSL "$url" -o "$dest" || {
		if [ -n "$hint" ]; then
			printf 'hint: %s\n' "$hint" >&2
		fi
		die "download failed: $url"
	}
}

# Accepts only the release payload allowlist; rejects absolute paths, parent
# traversal, dotfile members, and anything outside the published contract.
validate_archive_listing() {
	local archive="$1" listing verbose entry
	require_bin tar
	listing="$(tar -tzf "$archive")" || die "cannot read release archive"
	[ -n "$listing" ] || die "release archive is empty"
	while IFS= read -r entry; do
		case "$entry" in
		/* | ../* | */../* | */.. | .* | */./* | */. | */.* | *'\n'* | *'\r'*)
			die "unsafe release archive entry: $entry"
			;;
		install.sh | install.sh/ | VERSION | VERSION/ | skills | skills/ | skills/* | references | references/ | references/* | adapters | adapters/ | adapters/pi | adapters/pi/ | adapters/pi/manifest.yaml | adapters/pi/configs | adapters/pi/configs/ | adapters/pi/configs/* | adapters/pi/extensions | adapters/pi/extensions/ | adapters/pi/extensions/* | adapters/pi/packages | adapters/pi/packages/ | adapters/pi/packages/* | adapters/pi/scripts | adapters/pi/scripts/ | adapters/pi/scripts/* | tooling | tooling/ | tooling/install | tooling/install/ | tooling/install/common.sh | tooling/install/json_cleanup.py | tooling/install/jsonc.py | tooling/install/manifest_uninstall.py) ;;
		*)
			die "unexpected release archive entry: $entry"
			;;
		esac
	done <<EOF
$listing
EOF
	verbose="$(tar -tvzf "$archive")" || die "cannot inspect release archive members"
	while IFS= read -r entry; do
		case "$entry" in
		-* | d*) ;;
		*) die "release archive contains a non-file/non-directory member" ;;
		esac
	done <<EOF
$verbose
EOF
}

# Downloads the release tarball and checksum, verifies the digest, validates
# the archive layout, and extracts it. Sets VERIFIED_PAYLOAD (and DOWNLOAD_TMP,
# owned until process exit) in the caller's scope: this function must be
# called plainly, never inside a command substitution.
prepare_download_source() {
	local release_url checksum_url archive checksum expected actual extract bad_member latest_hint=""
	if [ -n "${B_AGENTIC_RELEASE_URL:-}${B_AGENTIC_CHECKSUM_URL:-}" ] && [ -n "$REF" ]; then
		warn "--ref=$REF is ignored while B_AGENTIC_RELEASE_URL/B_AGENTIC_CHECKSUM_URL overrides are set"
	fi
	if [ -n "$REF" ]; then
		release_url="${B_AGENTIC_RELEASE_URL:-$REPO_WEB_BASE/releases/download/$REF/b-agentic.tar.gz}"
		checksum_url="${B_AGENTIC_CHECKSUM_URL:-$REPO_WEB_BASE/releases/download/$REF/b-agentic.tar.gz.sha256}"
	else
		release_url="${B_AGENTIC_RELEASE_URL:-$RELEASE_URL_LATEST}"
		checksum_url="${B_AGENTIC_CHECKSUM_URL:-$CHECKSUM_URL_LATEST}"
		if [ -z "${B_AGENTIC_RELEASE_URL:-}" ]; then
			latest_hint="no b-agentic release may be published yet; the first vYYYY.MM.DD release tag must be pushed to $REPO_WEB_BASE before this installer can bootstrap"
		fi
	fi
	require_bin mktemp
	DOWNLOAD_TMP="$(mktemp -d "${TMPDIR:-/tmp}/b-agentic-download.XXXXXX")"
	archive="$DOWNLOAD_TMP/b-agentic.tar.gz"
	checksum="$DOWNLOAD_TMP/b-agentic.tar.gz.sha256"
	fetch_url "$release_url" "$archive" "$latest_hint"
	fetch_url "$checksum_url" "$checksum" ""
	expected="$(awk 'NF {print $1; exit}' "$checksum")"
	case "$expected" in
	'' | *[!0123456789abcdefABCDEF]*) die "checksum file does not contain a SHA-256 digest" ;;
	esac
	[ "${#expected}" -eq 64 ] || die "checksum file does not contain a 64-character SHA-256 digest"
	actual="$(sha256 "$archive")"
	[ "$actual" = "$expected" ] || die "release checksum mismatch: $archive does not match $checksum_url"
	validate_archive_listing "$archive"
	extract="$DOWNLOAD_TMP/extracted"
	mkdir "$extract"
	tar -xzf "$archive" -C "$extract" || die "cannot extract release archive"
	bad_member="$(find "$extract" -type l -print -quit)"
	[ -z "$bad_member" ] || die "release archive contains a symlink: $bad_member"
	[ -f "$extract/install.sh" ] && [ -f "$extract/VERSION" ] && [ -d "$extract/skills" ] && [ -d "$extract/references" ] || die "release archive is missing required files"
	VERIFIED_PAYLOAD="$extract"
}

yes_value() {
	case "${1:-}" in
	y | Y | yes | YES | Yes | true | TRUE | 1) return 0 ;;
	*) return 1 ;;
	esac
}

dry_run_enabled() {
	yes_value "$DRY_RUN_VALUE"
}

replace_memory_enabled() {
	yes_value "$REPLACE_MEMORY_VALUE"
}

uninstall_enabled() {
	yes_value "$UNINSTALL_VALUE"
}


can_prompt_api_keys() {
	! dry_run_enabled || return 1
	case "$PROMPT_API_KEYS_VALUE" in
	n | N | no | NO | No | false | FALSE | 0) return 1 ;;
	auto | AUTO | Auto | y | Y | yes | YES | Yes | true | TRUE | 1) ;;
	*) die "invalid B_AGENTIC_PROMPT_API_KEYS value: $PROMPT_API_KEYS_VALUE" ;;
	esac
	[ -r /dev/tty ] && [ -w /dev/tty ]
}

run_cmd() {
	if dry_run_enabled; then
		printf '[dry-run] %s\n' "$*" >&2
		return 0
	fi
	"$@"
}

require_bin() {
	command -v "$1" >/dev/null 2>&1 || die "required binary not found: $1"
}

require_python_311() {
	python3 - <<'PY' >/dev/null 2>&1 || die "Python 3.11+ is required."
import sys
sys.exit(0 if sys.version_info >= (3, 11) else 1)
PY
}

# True when this run must fetch a checksum-verified release bundle. Updates
# and uninstalls of an existing install operate purely on $LOCAL_REPO.
download_needed() {
	if [ "$OPERATION" = "update" ]; then
		return 1
	fi
	if uninstall_enabled; then
		if [ -e "$LOCAL_REPO/install.sh" ] || [ -d "$LOCAL_REPO/skills" ]; then
			return 1
		fi
		return 0
	fi
	return 0
}

require_sha256_tool() {
	if command -v sha256sum >/dev/null 2>&1; then
		return 0
	fi
	if command -v shasum >/dev/null 2>&1; then
		return 0
	fi
	die "required binary not found: sha256sum or shasum"
}

check_dependencies() {
	# Download prerequisites (curl, tar, mktemp, a SHA-256 tool) are enforced
	# in main() before the bootstrap fetch; the re-executed bundle run never
	# downloads, so the staged pipeline only needs the runtime tooling.
	require_bin python3
	require_python_311
	log "Using python3"
}

set_operation() {
	local next="$1"
	if [ "$OPERATION" != "install" ]; then
		die "--sync and --update cannot be combined"
	fi
	OPERATION="$next"
}

parse_args() {
	while [ "$#" -gt 0 ]; do
		case "$1" in
		--dry-run)
			DRY_RUN_VALUE=Y
			;;
		--replace-memory)
			REPLACE_MEMORY_VALUE=Y
			;;
		--preserve-memory)
			REPLACE_MEMORY_VALUE=N
			;;
		--uninstall)
			UNINSTALL_VALUE=Y
			;;
		--sync)
			set_operation "sync"
			;;
		--update)
			set_operation "update"
			;;
		--prompt-api-keys)
			PROMPT_API_KEYS_VALUE=Y
			;;
		--no-prompt-api-keys)
			PROMPT_API_KEYS_VALUE=N
			;;
		--runtime=* | --runtime)
			die "--runtime was replaced by --agent <name>; b-agentic installs the pi adapter only"
			;;
		--agent=*)
			AGENT="${1#--agent=}"
			[ -n "$AGENT" ] || die "invalid --agent: empty"
			;;
		--agent)
			shift
			[ "$#" -gt 0 ] || die "--agent requires a value (supported today: pi)"
			AGENT="$1"
			[ -n "$AGENT" ] || die "invalid --agent: empty"
			;;
		--ref=*)
			REF="${1#--ref=}"
			[ -n "$REF" ] || die "invalid ref: empty"
			;;
		--source-dir=*)
			SOURCE_DIR_EXPLICIT="${1#--source-dir=}"
			[ -n "$SOURCE_DIR_EXPLICIT" ] || die "invalid --source-dir: empty"
			;;
		--source-dir)
			shift
			[ "$#" -gt 0 ] || die "--source-dir requires a value"
			SOURCE_DIR_EXPLICIT="$1"
			[ -n "$SOURCE_DIR_EXPLICIT" ] || die "invalid --source-dir: empty"
			;;
		*)
			die "unknown argument: $1"
			;;
		esac
		shift
	done
}

validate_ref() {
	[ -n "$REF" ] || return 0
	[ "$OPERATION" != "update" ] || die "--ref cannot be used with --update"
	case "$REF" in
	-*) die "invalid ref: $REF (must not start with -)" ;;
	esac
	# Release refs are dated ordinal release tags (vYYYY.MM.DD.N, one per push
	# to main); bare dates, commit SHAs, and SemVer tags are not installable
	# pins. Bash 3.2-safe: glob the date portion, then verify the ordinal
	# suffix is non-empty and all digits.
	case "$REF" in
	v[0-9][0-9][0-9][0-9].[0-9][0-9].[0-9][0-9].*) ;;
	*) die "invalid ref: $REF (must be a vYYYY.MM.DD.N release tag, e.g. v$(date +%Y.%m.%d).1)" ;;
	esac
	local ordinal="${REF#v[0-9][0-9][0-9][0-9].[0-9][0-9].[0-9][0-9].}"
	case "$ordinal" in
	''|*[!0-9]*) die "invalid ref: $REF (must be a vYYYY.MM.DD.N release tag, e.g. v$(date +%Y.%m.%d).1)" ;;
	esac
}

resolve_agent_manifest() {
	local manifest="$SOURCE_DIR/adapters/$AGENT/manifest.yaml"
	[ -f "$manifest" ] || die "unknown agent '$AGENT': no adapter manifest at adapters/$AGENT/manifest.yaml (shipped today: pi)"
	local gate_status=0
	python3 - "$manifest" <<'PY' || gate_status=$?
import json
import sys

manifest = json.loads(open(sys.argv[1]).read())
if manifest.get("status") != "shipped":
    sys.exit(f"agent '{manifest.get('host')}' is verified but its installer is deferred; see docs/hosts.md")
PY
	return "$gate_status"
}

validate_operation() {
	if uninstall_enabled && [ "$OPERATION" != "install" ]; then
		die "--uninstall cannot be combined with --sync or --update"
	fi
	if [ -n "$SOURCE_DIR_EXPLICIT" ] && ! download_needed; then
		die "--source-dir cannot be combined with --update or with --uninstall on an installed b-agentic source"
	fi
}

set_source_dir() {
	SOURCE_DIR="$1"
	SKILLS_SRC="$SOURCE_DIR/skills"
	REFERENCES_SRC="$SOURCE_DIR/references"
	TEMPLATES_SRC="$SOURCE_DIR/adapters/pi/configs"
	KERNEL_SRC="$SOURCE_DIR/references/kernel.template.md"
}

validate_pi_source_layout() {
	[ -d "$SKILLS_SRC" ] || die "missing source directory: $SKILLS_SRC"
	[ -f "$SKILLS_SRC/registry.yaml" ] || die "missing skill registry: $SKILLS_SRC/registry.yaml"
	[ -d "$REFERENCES_SRC" ] || die "missing source directory: $REFERENCES_SRC"
	[ -f "$REFERENCES_SRC/capabilities.yaml" ] || die "missing capability contract: $REFERENCES_SRC/capabilities.yaml"
	[ -d "$TEMPLATES_SRC" ] || die "missing Pi config directory: $TEMPLATES_SRC"
	[ -f "$KERNEL_SRC" ] || die "missing Pi kernel source: $KERNEL_SRC"
	[ -f "$SOURCE_DIR/adapters/pi/scripts/install.sh" ] || die "missing Pi installer: $SOURCE_DIR/adapters/pi/scripts/install.sh"
	[ -f "$SOURCE_DIR/adapters/pi/extensions/b-agentic-support/capabilities.ts" ] || die "missing generated capability module: $SOURCE_DIR/adapters/pi/extensions/b-agentic-support/capabilities.ts"
	[ -f "$SOURCE_DIR/tooling/install/common.sh" ] || die "missing installer core: $SOURCE_DIR/tooling/install/common.sh"
	python3 - "$SKILLS_SRC/registry.yaml" "$SKILLS_SRC" <<'PY' || die "Pi skill payload does not match registry: $SKILLS_SRC"
import json
import sys
from pathlib import Path

registry_path, skills_path = map(Path, sys.argv[1:])
registry = json.loads(registry_path.read_text())
skills = registry.get("skills")
if not isinstance(skills, list):
    raise SystemExit("invalid skills registry")

names = []
for skill in skills:
    name = skill.get("name") if isinstance(skill, dict) else None
    if not isinstance(name, str) or not name:
        raise SystemExit("invalid skill name in registry")
    names.append(name)

missing = [name for name in names if not (skills_path / name / "SKILL.md").is_file()]
if missing:
    raise SystemExit(f"missing generated skill payloads: {', '.join(sorted(missing))}")
PY
}

# Restores $LOCAL_REPO after a failed or interrupted source installation.
# Runs under the sync EXIT/HUP/INT/TERM trap from the moment mutation is
# possible; SYNC_ROLLBACK_NEEDED plus SYNC_MUTATED/SYNC_COPIED keep repeated
# invocations idempotent and prevent rollback from ever destroying intact
# pre-existing state.
rollback_source_sync() {
	local entry
	if [ "$SYNC_ROLLBACK_NEEDED" -eq 1 ] && [ "$SYNC_MUTATED" -eq 1 ]; then
		warn "source installation failed; rolling back $LOCAL_REPO"
		if [ "$SYNC_MIGRATED" -eq 1 ] && [ -d "$SYNC_BACKUP_DIR" ]; then
			rm -rf "$LOCAL_REPO"
			mv "$SYNC_BACKUP_DIR" "$LOCAL_REPO"
		else
			for entry in "${MANAGED_PAYLOAD_ENTRIES[@]}"; do
				if [ -e "$SYNC_BACKUP_DIR/$entry" ]; then
					mkdir -p "$(dirname "$LOCAL_REPO/$entry")"
					rm -rf "${LOCAL_REPO:?}/$entry"
					mv "$SYNC_BACKUP_DIR/$entry" "$LOCAL_REPO/$entry"
				elif [ "$SYNC_COPIED" -eq 1 ] && [ -e "$LOCAL_REPO/$entry" ]; then
					rm -rf "${LOCAL_REPO:?}/$entry"
				fi
			done
		fi
	fi
	if [ -n "$SYNC_STAGE_DIR" ] && [ -d "$SYNC_STAGE_DIR" ]; then
		rm -rf "$SYNC_STAGE_DIR"
	fi
	if [ "$SYNC_MIGRATED" -eq 0 ] && [ -n "$SYNC_BACKUP_DIR" ] && [ -d "$SYNC_BACKUP_DIR" ]; then
		rm -rf "$SYNC_BACKUP_DIR"
	fi
	cleanup
	SYNC_STAGE_DIR=""
	SYNC_BACKUP_DIR=""
	SYNC_ROLLBACK_NEEDED=0
	SYNC_MUTATED=0
	SYNC_COPIED=0
}

# The managed marker on line 2 distinguishes installers this tool placed in
# $LOCAL_REPO from any foreign install.sh a user may have put there.
installer_marker_present() {
	local marker
	marker="$(sed -n '2p' "$LOCAL_REPO/install.sh")"
	[ "$marker" = "# B_AGENTIC_INSTALLER" ]
}

sync_source() {
	local payload="$1" entry
	[ -n "$payload" ] && [ -d "$payload" ] || die "verified release payload is missing"

	if dry_run_enabled; then
		log "Dry-run source: verified release payload at $payload (no fetch, no $LOCAL_REPO changes)"
		set_source_dir "$payload"
		resolve_agent_manifest || return 1
		return 0
	fi

	require_bin python3

	SYNC_MIGRATED=0
	SYNC_MUTATED=0
	SYNC_COPIED=0
	if [ -e "$LOCAL_REPO/.git" ]; then
		SYNC_MIGRATED=1
	elif [ -f "$LOCAL_REPO/install.sh" ] && ! installer_marker_present; then
		die "refusing to overwrite an unmanaged installer at $LOCAL_REPO/install.sh (line 2 is not the '# B_AGENTIC_INSTALLER' managed marker); move it aside or reinstall manually"
	fi

	# Arm rollback before anything destructive can happen.
	SYNC_ROLLBACK_NEEDED=1
	trap rollback_source_sync EXIT HUP INT TERM

	mkdir -p "$(dirname "$LOCAL_REPO")"

	# Stage the payload allowlist first so no $LOCAL_REPO mutation happens
	# before the payload is known complete.
	SYNC_STAGE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/b-agentic-stage.XXXXXX")"
	for entry in "${MANAGED_PAYLOAD_ENTRIES[@]}"; do
		[ -e "$payload/$entry" ] || die "release payload is missing required path: $entry"
		mkdir -p "$(dirname "$SYNC_STAGE_DIR/$entry")"
		cp -R "$payload/$entry" "$SYNC_STAGE_DIR/$entry"
	done

	if [ "$SYNC_MIGRATED" -eq 1 ]; then
		# Legacy git checkouts move aside wholesale: the old checkout (including
		# local modifications) is preserved verbatim and never merged.
		SYNC_BACKUP_DIR="${LOCAL_REPO}.backup.${TIMESTAMP}"
		SYNC_MUTATED=1
		log "Migrating legacy git checkout: $LOCAL_REPO -> $SYNC_BACKUP_DIR"
		mv "$LOCAL_REPO" "$SYNC_BACKUP_DIR"
	else
		SYNC_BACKUP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/b-agentic-backup.XXXXXX")"
		SYNC_MUTATED=1
		for entry in "${MANAGED_PAYLOAD_ENTRIES[@]}"; do
			if [ -e "$LOCAL_REPO/$entry" ]; then
				mkdir -p "$(dirname "$SYNC_BACKUP_DIR/$entry")"
				mv "$LOCAL_REPO/$entry" "$SYNC_BACKUP_DIR/$entry"
			fi
		done
	fi

	mkdir -p "$LOCAL_REPO"
	cp -R "$SYNC_STAGE_DIR/." "$LOCAL_REPO/"
	SYNC_COPIED=1
	[ -f "$LOCAL_REPO/install.sh" ] && [ -f "$LOCAL_REPO/VERSION" ] || die "staged payload did not install completely"

	SYNC_ROLLBACK_NEEDED=0
	trap - HUP INT TERM
	trap cleanup EXIT
	rm -rf "$SYNC_STAGE_DIR"
	if [ "$SYNC_MIGRATED" -eq 0 ]; then
		rm -rf "$SYNC_BACKUP_DIR"
	fi
	SYNC_STAGE_DIR=""
	SYNC_BACKUP_DIR=""

	log "Installed verified release payload into $LOCAL_REPO (VERSION $(cat "$LOCAL_REPO/VERSION"))"
	if [ "$SYNC_MIGRATED" -eq 1 ]; then
		# warn() prints through stage suppression so the backup path is always reported.
		warn "previous b-agentic checkout preserved at: ${LOCAL_REPO}.backup.${TIMESTAMP}"
	fi
	set_source_dir "$LOCAL_REPO"
	resolve_agent_manifest || return 1
	validate_pi_source_layout
}

require_local_source() {
	[ -d "$LOCAL_REPO/skills" ] || die "b-agentic source is not installed at $LOCAL_REPO; run the curl installer first"
	set_source_dir "$LOCAL_REPO"
	resolve_agent_manifest || return 1
	validate_pi_source_layout
}

prepare_source() {
	if [ "$OPERATION" = "update" ]; then
		require_local_source
		return 0
	fi
	if uninstall_enabled; then
		if [ -e "$LOCAL_REPO/install.sh" ] || [ -d "$LOCAL_REPO/skills" ]; then
			require_local_source
			return 0
		fi
		# Uninstall without an installed source runs from the verified payload
		# so manifest removal still has the uninstall helpers available.
		set_source_dir "$VERIFIED_PAYLOAD"
		resolve_agent_manifest || return 1
		validate_pi_source_layout
		return 0
	fi
	require_local_source
}

install_app() {
	if [ "$OPERATION" = "update" ]; then
		log "Using installed b-agentic source without refreshing"
		prepare_source
		return 0
	fi

	if uninstall_enabled; then
		log "Preparing uninstall source"
		prepare_source
		log "Uninstall source ready"
		return 0
	fi

	if [ -e "$LOCAL_REPO/install.sh" ] || [ -d "$LOCAL_REPO/skills" ]; then
		warn "b-agentic is already installed; running upgrade"
	else
		log "b-agentic is not installed; installing from the verified release bundle"
	fi

	sync_source "$VERIFIED_PAYLOAD"
	log "Installer source ready"
}

manifest_only_records() {
	python3 - <<'PY'
import json
import os
from pathlib import Path

home = Path.home()
candidates = []
candidates.extend(home.glob(".*/b-agentic/install.json"))
# Nested agent homes (e.g. ~/.pi/agent/b-agentic/install.json)
candidates.extend(home.glob(".*/*/b-agentic/install.json"))
candidates.extend((home / ".config").glob("*/b-agentic/install.json"))
candidates.extend((home / ".local" / "share").glob("*/b-agentic/install.json"))
candidates.extend((home / "Library" / "Application Support").glob("*/b-agentic/install.json"))
candidates.extend((home / ".gemini").glob("*/b-agentic/install.json"))
candidates.append(home / ".pi" / "agent" / "b-agentic" / "install.json")

allowed_roots = [home.resolve()]

seen = set()
for path in candidates:
    try:
        resolved = path.resolve()
        if not any(resolved.is_relative_to(root) for root in allowed_roots):
            continue
    except Exception:
        continue
    if resolved in seen or not path.is_file():
        continue
    seen.add(resolved)
    try:
        data = json.loads(path.read_text())
    except Exception:
        continue
    suite = data.get("suite")
    if suite is not None and suite != "b-agentic":
        continue
    runtime = data.get("runtime")
    if isinstance(runtime, str) and runtime:
        print(f"{runtime}\t{path}")
PY
}

manifest_only_uninstall_one() {
	local runtime_name="$1" manifest_path="$2"
	[ -f "$manifest_path" ] || return 1
	local installed_script
	installed_script="$(dirname "$manifest_path")/tooling/install/manifest_uninstall.py"
	if [ -f "$installed_script" ]; then
		run_cmd python3 "$installed_script" "$manifest_path"
		return $?
	fi
	if [ -n "${SOURCE_DIR:-}" ] && [ -f "$SOURCE_DIR/tooling/install/manifest_uninstall.py" ]; then
		run_cmd python3 "$SOURCE_DIR/tooling/install/manifest_uninstall.py" "$manifest_path"
		return $?
	fi
	die "manifest-only uninstall for $runtime_name requires $installed_script; reinstall once or restore the source checkout to uninstall safely"
}

try_manifest_only_uninstall() {
	uninstall_enabled || return 1
	{ [ -d "$LOCAL_REPO/.git" ] || [ -d "$LOCAL_REPO/skills" ]; } && return 1

	local product_name manifest_path
	while IFS=$'\t' read -r product_name manifest_path; do
		[ "$product_name" = "pi" ] || continue
		[ -f "$manifest_path" ] || continue
		manifest_only_uninstall_one "$PI_NAME" "$manifest_path"
		return $?
	done < <(manifest_only_records)
	return 1
}

prepare_user_bin_paths() {
	local -a candidates=()
	local path index

	[ -n "${UV_INSTALL_DIR:-}" ] && candidates+=("$UV_INSTALL_DIR")
	[ -n "${UV_TOOL_BIN_DIR:-}" ] && candidates+=("$UV_TOOL_BIN_DIR")
	[ -n "${XDG_BIN_HOME:-}" ] && candidates+=("$XDG_BIN_HOME")
	if [ -n "${XDG_DATA_HOME:-}" ]; then
		candidates+=("${XDG_DATA_HOME%/}/../bin")
	fi
	candidates+=("$HOME/.local/bin" "$HOME/.cargo/bin" "$HOME/.bun/bin")

	for ((index = ${#candidates[@]} - 1; index >= 0; index--)); do
		path="${candidates[$index]}"
		[ -n "$path" ] || continue
		case ":${PATH:-}:" in
		*":$path:"*) ;;
		*) PATH="$path:${PATH:-}" ;;
		esac
	done
	export PATH
}

install_rtk() {
	if command -v rtk >/dev/null 2>&1; then
		if dry_run_enabled; then
			printf '[dry-run] curl -fsSL https://raw.githubusercontent.com/rtk-ai/rtk/refs/heads/master/install.sh | sh\n' >&2
			return 0
		fi
		log "RTK already installed; upgrading"
		if curl -fsSL "https://raw.githubusercontent.com/rtk-ai/rtk/refs/heads/master/install.sh" | sh; then
			log "RTK upgraded"
		else
			warn "RTK upgrade failed"
			return 1
		fi
		return 0
	fi

	# Missing RTK is installed automatically; no TTY or confirmation is needed.

	if dry_run_enabled; then
		printf '[dry-run] curl -fsSL https://raw.githubusercontent.com/rtk-ai/rtk/refs/heads/master/install.sh | sh\n' >&2
		return 0
	fi

	log "Installing RTK"
	if curl -fsSL "https://raw.githubusercontent.com/rtk-ai/rtk/refs/heads/master/install.sh" | sh; then
		if command -v rtk >/dev/null 2>&1; then
			log "RTK installed"
		else
			die "RTK installed but not found on PATH; b-agentic requires RTK"
		fi
	else
		die "RTK installation failed; b-agentic requires RTK"
	fi
}

update_rtk() {
	log "Updating RTK"
	if ! command -v rtk >/dev/null 2>&1; then
		install_rtk
		return $?
	fi
	if dry_run_enabled; then
		printf '[dry-run] curl -fsSL https://raw.githubusercontent.com/rtk-ai/rtk/refs/heads/master/install.sh | sh\n' >&2
	elif curl -fsSL "https://raw.githubusercontent.com/rtk-ai/rtk/refs/heads/master/install.sh" | sh; then
		log "RTK updated"
	else
		warn "RTK update failed"
		return 1
	fi
}

update_codegraph() {
	log "Updating CodeGraph"
	if ! command -v codegraph >/dev/null 2>&1; then
		install_codegraph
		return $?
	fi
	if dry_run_enabled; then
		printf '[dry-run] CODEGRAPH_NO_INSTALL_REFRESH=1 codegraph upgrade\n' >&2
	elif CODEGRAPH_NO_INSTALL_REFRESH=1 codegraph upgrade; then
		log "CodeGraph updated"
	else
		warn "CodeGraph update failed"
		return 1
	fi
}

install_bun() {
	if command -v bun >/dev/null 2>&1; then
		if dry_run_enabled; then printf '[dry-run] bun upgrade\n' >&2; return 0; fi
		log "Updating Bun"
		bun upgrade || return 1
		return 0
	fi
	if dry_run_enabled; then
		printf '[dry-run] curl -fsSL https://bun.sh/install | bash\n' >&2
		return 0
	fi
	log "Installing Bun"
	curl -fsSL https://bun.sh/install | bash || return 1
	export PATH="$HOME/.bun/bin:$PATH"
	command -v bunx >/dev/null 2>&1 || { warn "Bun installed but bunx is not on PATH"; return 1; }
}

run_parallel_chains() {
	local log_dir
	log_dir="$(mktemp -d "${TMPDIR:-/tmp}/b-agentic-chains.XXXXXX")"
	local -a pids=() pid_indexes=() chains=() logs=() statuses=()
	local chain pid index position chain_index status rc=0
	for chain in "$@"; do
		index=${#chains[@]}; chains+=("$chain"); logs+=("$log_dir/$index.log")
		(
			# shellcheck disable=SC2034
			UI_HIDE_STAGES=1
			UI_SUPPRESS_LOGS=1
			"$chain"
		) >"${logs[$index]}" 2>&1 &
		pids+=("$!")
		pid_indexes+=("$index")
		if [ "${#pids[@]}" -ge 3 ]; then
			for position in "${!pids[@]}"; do
				pid="${pids[$position]}"
				chain_index="${pid_indexes[$position]}"
				if wait "$pid"; then
					statuses[chain_index]=0
				else
					status=$?
					statuses[chain_index]="$status"
					if [ "$rc" -eq 0 ] || [ "$status" -eq 2 ]; then rc="$status"; fi
				fi
			done
			pids=()
			pid_indexes=()
		fi
	done
	for position in "${!pids[@]}"; do
		pid="${pids[$position]}"
		chain_index="${pid_indexes[$position]}"
		if wait "$pid"; then
			statuses[chain_index]=0
		else
			status=$?
			statuses[chain_index]="$status"
			if [ "$rc" -eq 0 ] || [ "$status" -eq 2 ]; then rc="$status"; fi
		fi
	done
	if ui_tty_enabled && [ "$UI_STAGE_ACTIVE" -eq 1 ]; then
		ui_stage_finish "$rc"
	fi
	if dry_run_enabled; then
		for index in "${!chains[@]}"; do
			cat "${logs[$index]}"
		done
	else
		for index in "${!chains[@]}"; do
			awk '/^(warning:|b-agentic .* complete for Pi|Installed:|Planned:|Manifest:|Readiness:|Attention:|  [[:alnum:]_-]+:|Next:)/ { print }' "${logs[$index]}"
		done
	fi
	if [ "$rc" -ne 0 ]; then
		for index in "${!chains[@]}"; do
			if [ "${statuses[$index]:-0}" -ne 0 ]; then
				printf 'Dependency chain failed: %s\n' "${chains[$index]}" >&2
				if [ -s "${logs[$index]}" ]; then cat "${logs[$index]}" >&2; fi
			fi
		done
	fi
	rm -rf "$log_dir"
	return "$rc"
}

dependency_install_chain() {
	install_rtk
}

bun_install_chain() {
	install_bun
}

update_tooling() {
	set_install_stage_total 3
	run_parallel_chains update_rtk update_codegraph bun_install_chain
}

install_codegraph() {
	if command -v codegraph >/dev/null 2>&1; then
		if dry_run_enabled; then
			printf '[dry-run] CODEGRAPH_NO_INSTALL_REFRESH=1 codegraph upgrade\n' >&2
			return 0
		fi
		log "CodeGraph already installed; upgrading"
		if CODEGRAPH_NO_INSTALL_REFRESH=1 codegraph upgrade; then
			log "CodeGraph upgraded"
		else
			warn "CodeGraph upgrade failed"
			return 1
		fi
		return 0
	fi

	if dry_run_enabled; then
		printf '[dry-run] curl -fsSL https://raw.githubusercontent.com/colbymchenry/codegraph/main/install.sh | sh\n' >&2
		return 0
	fi

	log "Installing CodeGraph"
	if curl -fsSL https://raw.githubusercontent.com/colbymchenry/codegraph/main/install.sh | sh; then
		if command -v codegraph >/dev/null 2>&1; then
			log "CodeGraph installed"
		else
			warn "CodeGraph installed but not found on PATH"
			return 1
		fi
	else
		warn "CodeGraph installation failed"
		return 1
	fi
}

source_installer_core() {
	local common_src="$SOURCE_DIR/tooling/install/common.sh"
	[ -f "$common_src" ] || die "missing installer core: $common_src"
	# shellcheck disable=SC1090
	source "$common_src"
}

load_pi_installer() {
	local pi_script="$SOURCE_DIR/adapters/pi/scripts/install.sh"
	[ -f "$pi_script" ] || die "missing Pi installer: $pi_script"
	# shellcheck disable=SC1090
	source "$pi_script"
}

load_installer_sources() {
	source_installer_core
	resolve_agent_manifest || return 1
	validate_pi_source_layout
	load_pi_installer
}

main() {
	local rc=0

	ui_init
	parse_args "$@"
	validate_operation
	validate_ref

	if try_manifest_only_uninstall; then
		return 0
	fi

	if download_needed && [ -z "$SOURCE_DIR_EXPLICIT" ]; then
		# Enforce download prerequisites before fetching: the bootstrap downloads
		# before the staged pipeline runs, and the verified child never downloads.
		require_bin curl
		require_bin tar
		require_bin mktemp
		require_sha256_tool
		# The raw entrypoint is only a bootstrap: fetch the checksum-verified
		# release bundle and restart every state change from inside it, never
		# from the piped script. Plain call so DOWNLOAD_TMP is owned by this
		# process and removed by the EXIT cleanup.
		prepare_download_source
		log "Verified release payload: $VERIFIED_PAYLOAD"
		local child_rc=0
		if bash "$VERIFIED_PAYLOAD/install.sh" --source-dir "$VERIFIED_PAYLOAD" "$@"; then
			child_rc=0
		else
			child_rc=$?
		fi
		return "$child_rc"
	fi

	if [ -n "$SOURCE_DIR_EXPLICIT" ]; then
		[ -d "$SOURCE_DIR_EXPLICIT" ] || die "source directory does not exist: $SOURCE_DIR_EXPLICIT"
		VERIFIED_PAYLOAD="$SOURCE_DIR_EXPLICIT"
	fi

	ui_component_picker || return $?

	ui_set_stage_total 5
	run_ui_stage "Checking prerequisites" check_dependencies || return 1
	run_ui_stage "Preparing source" install_app || return 1
	run_ui_stage "Loading Pi installer" load_installer_sources || return 1
	prepare_user_bin_paths
	run_ui_stage "Checking optional shell tooling" install_shell_tools || return 1

	if uninstall_enabled; then
		set +e
		(
			set -e
			pi_uninstall
		)
		rc=$?
		set -e
		return "$rc"
	fi

	if [ "$OPERATION" = "install" ]; then
		run_ui_stage "Installing dependencies and Pi" run_parallel_chains dependency_install_chain install_codegraph bun_install_chain pi_install || return 1
	elif [ "$OPERATION" = "update" ]; then
		run_ui_stage "Updating dependencies and Pi" run_parallel_chains update_tooling pi_update || return 1
	fi

	if [ "$OPERATION" = "sync" ]; then
		set +e
		pi_sync
		rc=$?
		set -e
		[ "$rc" -eq 0 ] && summary_log "b-agentic sync complete for Pi"
		return "$rc"
	fi
	if [ "$OPERATION" = "update" ]; then
		summary_log "b-agentic update complete for Pi"
	fi
	return 0
}

main "$@"
