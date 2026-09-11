#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

fail_missing() {
	printf 'error: %s is required; %s\n' "$1" "$2" >&2
	exit 1
}

command -v git >/dev/null 2>&1 || fail_missing git "install Git and retry"
command -v python3 >/dev/null 2>&1 || fail_missing python3 "install Python 3.11+ and retry"
command -v ruff >/dev/null 2>&1 || fail_missing ruff "install Python quality tools with 'python3 -m pip install -r requirements-dev-quality.txt'"
command -v shellcheck >/dev/null 2>&1 || fail_missing shellcheck "install Python quality tools with 'python3 -m pip install -r requirements-dev-quality.txt'"

ESLINT="$ROOT_DIR/node_modules/.bin/eslint"
PRETTIER="$ROOT_DIR/node_modules/.bin/prettier"
MARKDOWNLINT="$ROOT_DIR/node_modules/.bin/markdownlint-cli2"
[ -x "$ESLINT" ] || fail_missing eslint "install root development tools with 'npm ci'"
[ -x "$PRETTIER" ] || fail_missing prettier "install root development tools with 'npm ci'"
[ -x "$MARKDOWNLINT" ] || fail_missing markdownlint-cli2 "install root development tools with 'npm ci'"

PI_TSC="$ROOT_DIR/adapters/pi/node_modules/.bin/tsc"
[ -x "$PI_TSC" ] || fail_missing "Pi TypeScript dependencies" "install them with 'npm ci --prefix pi'"
[ -d "$ROOT_DIR/adapters/pi/node_modules/@earendil-works/pi-coding-agent" ] || fail_missing "@earendil-works/pi-coding-agent" "install Pi dependencies with 'npm ci --prefix pi'"
[ -d "$ROOT_DIR/adapters/pi/node_modules/@earendil-works/pi-tui" ] || fail_missing "@earendil-works/pi-tui" "install Pi dependencies with 'npm ci --prefix pi'"

is_generated_delivery() {
	case "$1" in
	skills/*/SKILL.md|adapters/pi/extensions/b-agentic-support/mcp.ts|adapters/pi/extensions/b-agentic-support/permissions-data.ts|tooling/validate/behavior.py|tooling/validate/shared.py)
		return 0
		;;
	*)
		return 1
		;;
	esac
}

is_json_compatible_yaml() {
	case "$1" in
	references/mcp_operations.yaml|skills/registry.yaml) return 0 ;;
	*) return 1 ;;
	esac
}

is_generator_coupled_source() {
	case "$1" in
	README.md|references/kernel.template.md|skills/*/prompt.md) return 0 ;;
	*) return 1 ;;
	esac
}

typescript_lint_files=()
python_files=()
python_format_files=()
shell_files=()
markdown_files=()
prettier_files=()

# Enumerate tracked paths rather than relying on shell globs. This keeps checks
# correct for nested files, paths with spaces, and shell scripts without a
# conventional extension when their shebang identifies them as shell.
while IFS= read -r -d '' path; do
	[ -f "$path" ] || continue
	case "$path" in
	*.ts|*.tsx)
		if ! is_generated_delivery "$path"; then
			typescript_lint_files+=("$path")
			prettier_files+=("$path")
		fi
		;;
	*.py)
		python_files+=("$path")
		if ! is_generated_delivery "$path"; then
			python_format_files+=("$path")
		fi
		;;
	*.sh|*.bash)
		shell_files+=("$path")
		;;
	*.md)
		if ! is_generated_delivery "$path"; then
			markdown_files+=("$path")
			if ! is_generator_coupled_source "$path"; then
				prettier_files+=("$path")
			fi
		fi
		;;
	*.json|*.jsonc|*.mjs|*.yml)
		prettier_files+=("$path")
		;;
	*.yaml)
		if ! is_json_compatible_yaml "$path"; then
			prettier_files+=("$path")
		fi
		;;
	*)
		first_line=''
		if IFS= read -r first_line < "$path"; then
			case "$first_line" in
			'#!'*/bash|'#!'*/sh|'#!'*/zsh)
				shell_files+=("$path")
				;;
			esac
		fi
		;;
	esac
done < <(git ls-files -z)

run_if_files() {
	local label="$1" count="$2"
	shift 2
	if [ "$count" -eq 0 ]; then
		printf '%s skipped: no tracked files\n' "$label"
		return 0
	fi
	printf '%s\n' "$label"
	"$@"
}

run_if_files "ESLint" "${#typescript_lint_files[@]}" "$ESLINT" --max-warnings=0 --no-warn-ignored "${typescript_lint_files[@]}"
run_if_files "Prettier" "${#prettier_files[@]}" "$PRETTIER" --check "${prettier_files[@]}"
run_if_files "Ruff lint" "${#python_files[@]}" ruff check "${python_files[@]}"
run_if_files "Ruff format check" "${#python_format_files[@]}" ruff format --check "${python_format_files[@]}"
run_if_files "ShellCheck" "${#shell_files[@]}" shellcheck --shell=bash --external-sources "${shell_files[@]}"
run_if_files "Markdownlint" "${#markdown_files[@]}" "$MARKDOWNLINT" --config .markdownlint-cli2.jsonc "${markdown_files[@]}"

printf 'Pi TypeScript typecheck\n'
bash "$ROOT_DIR/adapters/pi/scripts/typecheck.sh"
printf 'Repository quality checks passed.\n'
