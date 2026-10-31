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

# Drive the plugin the way OpenCode V2 does: setup(ctx) registers an execute.before hook, and a
# throw from it fails the call.
cat >"$work/call.mjs" <<'JS'
const [, , plugin, tool, args, cwd] = process.argv;
const mod = await import(plugin);
const registered = [];
await mod.default.setup({
  location: { directory: cwd },
  tool: { hook: async (name, callback) => { registered.push({ name, callback }); return { dispose: async () => {} }; } },
});
if (registered.length !== 1 || registered[0].name !== "execute.before") {
  process.stdout.write(`block setup registered ${JSON.stringify(registered.map((hook) => hook.name))}\n`);
  process.exit(0);
}
try {
  await registered[0].callback({ tool, input: JSON.parse(args) });
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
import(process.argv[1]).then(async (mod) => {
  const plugin = mod.default;
  if (typeof plugin.id !== "string" || typeof plugin.setup !== "function" || "server" in plugin) process.exit(1);
  const names = [];
  await plugin.setup({ tool: { hook: async (name) => { names.push(name); } } });
  process.exit(names.length === 1 && names[0] === "execute.before" ? 0 : 1);
});
' "$oc/plugins/b-agentic.mjs" || fail "default export must be { id, setup } registering exactly one execute.before tool hook"

# --- file tools -------------------------------------------------------------
check read-env block read '{"path":"/repo/.env"}' 'likely-secret path'
check read-env-v1-key block read '{"filePath":"/repo/.env"}' 'likely-secret path'
check read-env-example pass read '{"path":"/repo/.env.example"}'
check edit-pem block edit '{"path":"/repo/keys/server.pem"}'
check write-credentials block write '{"path":"/repo/credentials.json"}'
check glob-pem block glob '{"pattern":"**/*.pem"}'
check grep-include-env block grep '{"pattern":"TOKEN","include":"*.env"}'
check grep-content-pattern pass grep '{"pattern":"credentials"}'
check read-source pass read '{"filePath":"/repo/src/index.ts"}'
patch_args() { jq -cn --arg p "$1" '{patchText: $p}'; }
check patch-delete-env block patch "$(patch_args $'*** Begin Patch\n*** Delete File: .env.production\n*** End Patch')" 'likely-secret path'
check patch-add-pem block patch "$(patch_args $'*** Begin Patch\n*** Add File: keys/server.pem\n+x\n*** End Patch')" 'likely-secret path'
check patch-move-to-credentials block patch "$(patch_args $'*** Begin Patch\n*** Update File: src/a.ts\n*** Move to: credentials.json\n@@\n-a\n+b\n*** End Patch')" 'likely-secret path'
check patch-move-from-env block patch "$(patch_args $'*** Begin Patch\n*** Update File: .env\n*** Move to: src/a.txt\n*** End Patch')" 'likely-secret path'
check patch-indented-delete-env block patch "$(patch_args $'*** Begin Patch\n  *** Delete File: .env\n*** End Patch')" 'likely-secret path'
check patch-indented-add-env block patch "$(patch_args $'*** Begin Patch\n\t*** Add File: .env\n+x\n*** End Patch')" 'likely-secret path'
check patch-indented-update-pem block patch "$(patch_args $'*** Begin Patch\n   *** Update File: keys/a.pem\n*** End Patch')" 'likely-secret path'
check patch-indented-move-credentials block patch "$(patch_args $'*** Begin Patch\n*** Update File: src/a.ts\n  *** Move to: credentials.json\n*** End Patch')" 'likely-secret path'
check patch-nbsp-path block patch "$(patch_args $'*** Begin Patch\n*** Delete File: .env \n*** End Patch')" 'likely-secret path'
check patch-crlf-headers block patch "$(patch_args $'*** Begin Patch\r\n*** Delete File: .env\r\n*** End Patch\r\n')" 'likely-secret path'
check patch-lowercase-header block patch "$(patch_args $'*** Begin Patch\n*** delete file: .env\n*** End Patch')" 'likely-secret path'
check patch-cr-in-path block patch "$(patch_args $'*** Begin Patch\n*** Delete File: safe\r/../.env\n*** End Patch')" 'likely-secret path'
check patch-cr-hidden-name block patch "$(patch_args $'*** Begin Patch\n*** Delete File: .env\rsafe\n*** End Patch')" 'likely-secret path'
check patch-ls-in-path block patch "$(patch_args $'*** Begin Patch\n*** Delete File: safe\u2028/../.env\n*** End Patch')" 'likely-secret path'
check patch-ps-in-move block patch "$(patch_args $'*** Begin Patch\n*** Update File: src/a.ts\n*** Move to: safe\u2029/../credentials.json\n*** End Patch')" 'likely-secret path'
check patch-source pass patch "$(patch_args $'*** Begin Patch\n*** Update File: src/a.ts\n@@\n-a\n+b\n*** End Patch')"
check patch-env-example pass patch "$(patch_args $'*** Begin Patch\n*** Update File: .env.example\n@@\n-a\n+b\n*** End Patch')"
check patch-no-text pass patch '{}'
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

# --- shell: a relative workdir resolves against the session location, not the server's cwd ---
other="$work/other"
mkdir -p "$other"
git -C "$other" init -q .
git -C "$other" config user.email probe@example.invalid
git -C "$other" config user.name probe
printf 'b\n' >"$other/b.txt"
git -C "$other" add .
git -C "$other" commit -qm init
in_location() { # <location> <tool> <args-json>: runs from the approved repo, like a server started elsewhere
  out=$(cd "$repo" && node "$work/call.mjs" "$oc/plugins/b-agentic.mjs" "$2" "$3" "$1")
}
for workdir in other ./other; do
  in_location "$work" bash "$(jq -cn --arg c "$review" --arg w "$workdir" '{command: $c, workdir: $w}')"
  [[ "$out" == block*'has not approved'* ]] || fail "workdir $workdir must be checked in the unapproved repository: $out"
done
in_location "$work" bash "$(jq -cn --arg c "$review" '{command: $c, workdir: "repo"}')"
[ "$out" = pass ] || fail "a relative workdir in the approved repository should pass: $out"
in_location "$other" bash "$(jq -cn --arg c "$review" '{command: $c, workdir: "../repo"}')"
[ "$out" = pass ] || fail "a parent-relative workdir in the approved repository should pass: $out"
in_location "$repo" bash "$(jq -cn --arg c "$review" '{command: $c}')"
[ "$out" = pass ] || fail "no workdir should use the session location: $out"
in_location "$other" bash "$(jq -cn --arg c "$review" '{command: $c}')"
[[ "$out" == block*'has not approved'* ]] || fail "no workdir in the unapproved location must be refused: $out"
node --input-type=module -e '
import(process.argv[1]).then(({ shellCwd }) => {
  const home = process.env.HOME;
  const cases = [[undefined, "/s", "/s"], ["", "/s", "/s"], ["a", "/s", "/s/a"], ["../a", "/s/b", "/s/a"], ["/x", "/s", "/x"], ["~/x", "/s", home + "/x"], ["~", "/s", home]];
  for (const [workdir, base, want] of cases)
    if (shellCwd(workdir, base) !== want) { console.error("shellCwd", workdir, base, shellCwd(workdir, base)); process.exit(1); }
});
' "$oc/plugins/b-agentic.mjs" || fail "shellCwd must resolve workdir against the session location"

echo "opencode plugin probe passed"
