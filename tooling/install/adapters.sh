#!/usr/bin/env bash
# adapters.sh - Host adapter discovery, gating, and dispatch.
#
# Sourced by install.sh after set_source_dir(), so every helper reads
# $SOURCE_DIR and reports failures through the entrypoint's die()/warn().
#
# Adapter contract
# ----------------
# adapters/<host>/manifest.yaml declares:
#   host          the adapter id; must equal the directory name
#   status        "shipped" (installable) or "deferred" (documented only)
#   display_name  human label used in stage labels and summaries
#   installer     repo-relative path to the adapter installer script
#   payload       adapter-relative entries that ship in the release bundle
#
# adapters/<host>/scripts/install.sh defines, where <prefix> is the host name
# with every '-' replaced by '_':
#   <prefix>_set_source_dirs   point the shared *_SRC paths at this adapter
#   <prefix>_validate_source   fail when the adapter payload is incomplete
#   <prefix>_install           first-time and upgrade install
#   <prefix>_sync              re-apply managed assets only
#   <prefix>_update            refresh managed assets and host tooling
#   <prefix>_uninstall         remove managed assets recorded in the manifest
#
# Each dispatch sources the adapter in a fresh subshell (adapter_run). That is
# what lets an adapter mark its own managed destination paths readonly at
# source time — the Pi adapter does — without one adapter in a multi-host run
# colliding with another's paths or leaking state into the entrypoint.
#
# Deferred adapters ship manifest.yaml alone; the gate below turns a selection
# into an explicit, documented error instead of a partial install.

# claude-code -> claude_code
adapter_prefix() {
	printf '%s' "${1//-/_}"
}

adapter_manifest_path() {
	printf '%s/adapters/%s/manifest.yaml' "$SOURCE_DIR" "$1"
}

# Reads one top-level manifest string field. Prints the default when the field
# is absent; fails when the manifest is unreadable or not an object.
adapter_manifest_value() {
	local host="$1" key="$2" fallback="${3:-}" manifest
	manifest="$(adapter_manifest_path "$host")"
	[ -f "$manifest" ] || die "unknown agent '$host': no adapter manifest at adapters/$host/manifest.yaml"
	python3 - "$manifest" "$key" "$fallback" <<'PY' || die "unreadable adapter manifest: adapters/$host/manifest.yaml"
import json
import sys

manifest_path, key, fallback = sys.argv[1:4]
try:
    data = json.loads(open(manifest_path).read())
except Exception as exc:  # noqa: BLE001 - surfaced verbatim to the installer
    raise SystemExit(f"invalid manifest JSON: {exc}")
if not isinstance(data, dict):
    raise SystemExit("manifest is not an object")
value = data.get(key, fallback)
if not isinstance(value, str):
    value = fallback
print(value)
PY
}

# Prints every adapter directory that carries a manifest, newline separated.
adapter_known_hosts() {
	local manifest host
	for manifest in "$SOURCE_DIR"/adapters/*/manifest.yaml; do
		[ -f "$manifest" ] || continue
		host="$(basename "$(dirname "$manifest")")"
		printf '%s\n' "$host"
	done
}

adapter_shipped_hosts() {
	local host
	while IFS= read -r host; do
		[ -n "$host" ] || continue
		if [ "$(adapter_manifest_value "$host" status deferred)" = "shipped" ]; then
			printf '%s\n' "$host"
		fi
	done < <(adapter_known_hosts)
}

adapter_shipped_list() {
	local host joined=""
	while IFS= read -r host; do
		[ -n "$host" ] || continue
		if [ -n "$joined" ]; then joined="$joined, $host"; else joined="$host"; fi
	done < <(adapter_shipped_hosts)
	printf '%s' "${joined:-none}"
}

adapter_display_name() {
	local name
	name="$(adapter_manifest_value "$1" display_name "$1")"
	printf '%s' "$name"
}

# Fails unless the adapter exists, names itself consistently, and is shipped.
adapter_require_shipped() {
	local host="$1" manifest declared status
	manifest="$(adapter_manifest_path "$host")"
	if [ ! -f "$manifest" ]; then
		die "unknown agent '$host': no adapter manifest at adapters/$host/manifest.yaml (shipped today: $(adapter_shipped_list))"
	fi
	declared="$(adapter_manifest_value "$host" host "")"
	[ "$declared" = "$host" ] || die "adapter manifest host '$declared' does not match directory adapters/$host"
	status="$(adapter_manifest_value "$host" status deferred)"
	if [ "$status" != "shipped" ]; then
		die "agent '$host' is verified but its installer is deferred; see docs/hosts.md (shipped today: $(adapter_shipped_list))"
	fi
}

adapter_installer_script() {
	local host="$1" relative
	relative="$(adapter_manifest_value "$host" installer "adapters/$host/scripts/install.sh")"
	printf '%s/%s' "$SOURCE_DIR" "$relative"
}

# Warns when two selected adapters will surface the same skills twice.
#
# Hosts do not share a managed skills directory — each adapter writes only its
# own native path — but some hosts additionally *read* another host's
# directory (OpenCode reads .claude/skills; see docs/hosts.md). Installing
# both is safe and reversible, so this reports rather than blocks.
adapter_warn_skill_overlap() {
	local selected=" $* " host source manifest
	for host in "$@"; do
		manifest="$(adapter_manifest_path "$host")"
		[ -f "$manifest" ] || continue
		while IFS= read -r source; do
			[ -n "$source" ] || continue
			case "$selected" in
			*" $source "*)
				warn "$(adapter_display_name "$host") also discovers $(adapter_display_name "$source") skills; the same skills will appear from both installs"
				;;
			esac
		done < <(python3 -c '
import json, sys
data = json.load(open(sys.argv[1]))
value = data.get("reads_skills_from")
if isinstance(value, list):
    print("\n".join(entry for entry in value if isinstance(entry, str)))
' "$manifest")
	done
}

# Fails unless the adapter installer exists and defines the whole contract.
# Runs in a subshell so the check never leaves the adapter loaded.
adapter_check_contract() {
	local host="$1" script prefix
	prefix="$(adapter_prefix "$host")"
	script="$(adapter_installer_script "$host")"
	[ -f "$script" ] || die "missing $(adapter_display_name "$host") installer: $script"
	(
		# shellcheck disable=SC1090
		source "$script"
		for verb in set_source_dirs validate_source install sync update uninstall; do
			declare -f "${prefix}_${verb}" >/dev/null 2>&1 ||
				die "adapter '$host' does not define ${prefix}_${verb}; see the contract in tooling/install/adapters.sh"
		done
	)
}

# Dispatches one contract verb to the named adapter in an isolated subshell.
# <prefix>_set_source_dirs always runs first so the verb sees this adapter's
# source paths, never the previous adapter's.
adapter_run() {
	local host="$1" verb="$2" script prefix
	shift 2
	prefix="$(adapter_prefix "$host")"
	script="$(adapter_installer_script "$host")"
	[ -f "$script" ] || die "missing $(adapter_display_name "$host") installer: $script"
	(
		# Read by the adapter script and the installer core.
		# shellcheck disable=SC2034
		AGENT="$host"
		# shellcheck disable=SC1090
		source "$script"
		declare -f "${prefix}_${verb}" >/dev/null 2>&1 ||
			die "adapter '$host' does not define ${prefix}_${verb}"
		"${prefix}_set_source_dirs"
		"${prefix}_${verb}" "$@"
	)
}
