#!/usr/bin/env bash
# Exercise the OpenCode safety plugin against an installed-style layout
# (plugins/, b-agentic/hooks, b-agentic/bin) in a throwaway directory. Needs only
# node, git, and jq: no OpenCode, credentials, network, or Codex.
# shellcheck disable=SC2016 # Single-quoted shell commands with literal $ are the inputs under test.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
work=$(mktemp -d)
trap 'chmod -R u+rwX "$work" 2>/dev/null; rm -rf "$work"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export GIT_CEILING_DIRECTORIES="$work"
unset B_AGENTIC_STATE_DIR

fail() { echo "opencode plugin probe failed: $*" >&2; exit 1; }

oc="$work/opencode"
mkdir -p "$oc/plugins" "$oc/b-agentic/hooks" "$oc/b-agentic/bin"
cp "$root/opencode/plugins/b-agentic.js" "$oc/plugins/b-agentic.mjs"
cp "$root"/claude/hooks/*.mjs "$oc/b-agentic/hooks/"
cp "$root"/claude/bin/*.mjs "$oc/b-agentic/bin/"

repo="$work/repo"
mkdir -p "$repo"
git -C "$repo" init -q .
git -C "$repo" config user.email probe@example.invalid
git -C "$repo" config user.name probe
printf 'a\n' >"$repo/a.txt"
git -C "$repo" add .
git -C "$repo" commit -qm init

# Drive the plugin's tool.execute.before hook the way OpenCode does.
cat >"$work/call.mjs" <<'JS'
const [, , plugin, tool, args, cwd] = process.argv;
const mod = await import(plugin);
const hooks = await mod.default.server({ directory: cwd });
try {
  await hooks["tool.execute.before"]({ tool }, { args: JSON.parse(args) });
  process.stdout.write("pass\n");
} catch (error) {
  process.stdout.write(`block ${error.message}\n`);
}
JS

out=""
call() { out=$(node "$work/call.mjs" "$oc/plugins/b-agentic.mjs" "$1" "$2" "$repo"); }
# check <name> <pass|block> <tool> <args-json> [reason-substring]
check() {
  local name=$1 expect=$2 tool=$3 args=$4 reason=${5:-}
  call "$tool" "$args"
  case "$expect" in
    pass) [ "$out" = pass ] || fail "$name should pass: $out" ;;
    block)
      [[ "$out" == block* ]] || fail "$name should be blocked: $out"
      [ -z "$reason" ] || grep -Fq -- "$reason" <<<"$out" || fail "$name reason missing '$reason': $out"
      ;;
  esac
}

node -e '
import(process.argv[1]).then((mod) => {
  const plugin = mod.default;
  if (typeof plugin.id !== "string" || typeof plugin.server !== "function") process.exit(1);
  return plugin.server({}).then((hooks) => process.exit(typeof hooks["tool.execute.before"] === "function" ? 0 : 1));
});
' "$oc/plugins/b-agentic.mjs" || fail "default export must be { id, server } returning tool.execute.before"

# --- file tools -------------------------------------------------------------
check read-env block read '{"filePath":"/repo/.env"}' 'likely-secret path'
check read-env-example pass read '{"filePath":"/repo/.env.example"}'
check edit-pem block edit '{"filePath":"/repo/keys/server.pem"}'
check write-credentials block write '{"filePath":"/repo/credentials.json"}'
check glob-pem block glob '{"pattern":"**/*.pem"}'
check grep-include-env block grep '{"pattern":"TOKEN","include":"*.env"}'
check grep-content-pattern pass grep '{"pattern":"credentials"}'
check read-source pass read '{"filePath":"/repo/src/index.ts"}'
check unknown-tool pass question '{"filePath":"/repo/.env"}'
check malformed-args pass read 'null'

# --- shell: Codex guard -------------------------------------------------------
companion='codex-compan''ion.mjs'
review="node \"/plugin/scripts/$companion\" adversarial-review --wait --scope working-tree check the diff"
check shell-unrelated pass bash '{"command":"ls -la"}'
check shell-status pass shell "$(jq -cn --arg c "node /p/$companion status" '{command: $c}')"
check shell-unapproved block bash "$(jq -cn --arg c "$review" '{command: $c}')" 'has not approved'
grep -Fq "$oc/b-agentic/hooks/b-codex-guard.mjs --approve" <<<"$out" || fail "approve hint must name the installed guard: $out"
if grep -Fq 'AskUserQuestion' <<<"$out"; then fail "OpenCode wording must say question, not AskUserQuestion"; fi
(cd "$repo" && node "$oc/b-agentic/hooks/b-codex-guard.mjs" --approve >/dev/null)
[ -f "$oc/b-agentic/codex-approved-repos.json" ] || fail "approvals must live beside the installed hooks"
check shell-approved pass bash "$(jq -cn --arg c "$review" '{command: $c}')"
check shell-background block bash "$(jq -cn --arg c "node /p/$companion review --background --scope working-tree" '{command: $c}')" 'foreground'

echo "opencode plugin probe passed"
