#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

fail_missing() {
  printf 'error: %s is required; %s\n' "$1" "$2" >&2
  exit 1
}

command -v python3 >/dev/null 2>&1 || fail_missing python3 "install Python 3.11+ and retry"
command -v ruff >/dev/null 2>&1 || fail_missing ruff "install Python quality tools with 'python3 -m pip install -r requirements-dev-quality.txt'"
command -v shellcheck >/dev/null 2>&1 || fail_missing shellcheck "install ShellCheck and retry"
PRETTIER="$ROOT_DIR/node_modules/.bin/prettier"
MARKDOWNLINT="$ROOT_DIR/node_modules/.bin/markdownlint-cli2"
[ -x "$PRETTIER" ] || fail_missing prettier "install root development tools with 'npm ci'"
[ -x "$MARKDOWNLINT" ] || fail_missing markdownlint-cli2 "install root development tools with 'npm ci'"

is_generated() {
  case "$1" in skills/*/SKILL.md|opencode/commands/*|opencode/configs/opencode.user.template.json) return 0;; *) return 1;; esac
}
is_json_compatible_yaml() {
  case "$1" in references/mcp_operations.yaml|references/capabilities.yaml|skills/registry.yaml) return 0;; *) return 1;; esac
}

python_files=() shell_files=() markdown_files=() prettier_files=()
while IFS= read -r -d '' path; do
  [ -f "$path" ] || continue
  is_generated "$path" && continue
  case "$path" in
    *.py) python_files+=("$path") ;;
    *.sh|*.bash) shell_files+=("$path") ;;
    *.md) markdown_files+=("$path"); prettier_files+=("$path") ;;
    *.json|*.jsonc|*.yml) prettier_files+=("$path") ;;
    *.yaml) is_json_compatible_yaml "$path" || prettier_files+=("$path") ;;
    *)
      first_line="$(head -n 1 "$path" 2>/dev/null || true)"
      case "$first_line" in '#!'*/bash|'#!'*/sh) shell_files+=("$path");; esac
      ;;
  esac
done < <(git ls-files -co --exclude-standard -z)

run_if_files() {
  local label="$1" count="$2"
  shift 2
  [ "$count" -eq 0 ] && { printf '%s skipped: no tracked files\n' "$label"; return 0; }
  printf '%s\n' "$label"
  "$@"
}

run_if_files 'Prettier' "${#prettier_files[@]}" "$PRETTIER" --check "${prettier_files[@]}"
run_if_files 'Ruff lint' "${#python_files[@]}" ruff check "${python_files[@]}"
run_if_files 'Ruff format check' "${#python_files[@]}" ruff format --check "${python_files[@]}"
run_if_files 'ShellCheck' "${#shell_files[@]}" shellcheck --shell=bash --external-sources "${shell_files[@]}"
run_if_files 'Markdownlint' "${#markdown_files[@]}" "$MARKDOWNLINT" --config .markdownlint-cli2.jsonc "${markdown_files[@]}"
printf 'Repository quality checks passed.\n'
