#!/usr/bin/env bash
# Exercise tooling/install/pi_install.py (through install.sh --runtime=pi) in sandbox HOME directories. Needs
# python3, git, node, and jq: no network, credentials, Pi, or package manager. Every scenario owns a private HOME
# and logging shims stand in for npm, npx, pnpm, yarn, curl, wget, and pi, so the probe proves what the installer
# runs. Nothing outside the throwaway work directory is read or written.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
work=$(mktemp -d)
trap 'chmod -R u+rwX "$work" 2>/dev/null; rm -rf "$work"' EXIT

fail() { echo "pi install probe failed: $*" >&2; exit 1; }
for tool in jq node git python3; do command -v "$tool" >/dev/null 2>&1 || fail "this probe needs $tool on PATH"; done

# Logging shims: every call is appended to $calls, so a package manager or download shows up as a failure.
shims="$work/shims"
calls="$work/calls.log"
mkdir -p "$shims"
: >"$calls"
for tool in npm npx pnpm yarn curl wget; do
  printf '#!/bin/sh\necho "%s $*" >>"%s"\nexit 0\n' "$tool" "$calls" >"$shims/$tool"
done
cat >"$shims/pi" <<EOF
#!/bin/sh
echo "pi \$* offline=\${PI_OFFLINE:-}" >>"$calls"
[ "\$1" = "--version" ] || exit 2
# FAKE_PI_TOUCH stands in for an editor or Pi saving a file while the version probe runs.
if [ -n "\${FAKE_PI_TOUCH:-}" ]; then mkdir -p "\$(dirname "\$FAKE_PI_TOUCH")"; printf '{"edited_during_probe":true}\\n' >"\$FAKE_PI_TOUCH"; fi
echo "\${FAKE_PI_VERSION:-1.6.0}"
EOF
chmod +x "$shims"/*

# A PATH without any pi: the shims' directory is left out and the system directories hold none.
nopi="$work/nopi"
mkdir -p "$nopi"
for tool in python3 git; do ln -s "$(command -v "$tool")" "$nopi/$tool"; done
PATH="$nopi:/usr/bin:/bin" command -v pi >/dev/null 2>&1 && fail "a pi is installed in /usr/bin or /bin, so the missing-pi case cannot run"

out="" err="" rc=0
# run <home> [args...]: install.sh --runtime=pi with the shims first on PATH; stdout to $out, stderr to $err.
run() {
  local home=$1
  shift
  rc=0
  out=$(env -u PI_CODING_AGENT_DIR HOME="$home" PATH="$shims:$PATH" bash "$root/install.sh" --runtime=pi "$@" 2>"$work/stderr") || rc=$?
  err=$(cat "$work/stderr")
}
expect_ok() { [ "$rc" -eq 0 ] || fail "$1: exit $rc: $err $out"; }
expect_refused() { [ "$rc" -ne 0 ] || fail "$1 must be refused: $out"; }
# tree <dir>: sorted `sha256  relative-path` list of files and symlinks, backups excluded.
tree() {
  # shellcheck disable=SC2016 # The inner script runs in sh and expands its own variables.
  ( cd "$1" && find . \( -type f -o -type l \) -not -path '*/b-agentic/backups/*' -print0 \
      | sort -z | xargs -0 -r sh -c 'for f; do if [ -L "$f" ]; then printf "link %s -> %s\n" "$f" "$(readlink "$f")"; else printf "%s  %s\n" "$(sha256sum "$f" | cut -d" " -f1)" "$f"; fi; done' _ )
}
# canonical_tree <dir>: like tree, but JSON files are compared by content and key order (rule order decides a verdict),
# since a merge rewrites their formatting.
canonical_tree() {
  local file
  ( cd "$1" && find . -type f -not -path '*/b-agentic/backups/*' | sort | while IFS= read -r file; do
      case "$file" in
        *.json) printf '%s  %s\n' "$(jq -c . "$file")" "$file" ;;
        *) printf '%s  %s\n' "$(sha256sum "$file" | cut -d' ' -f1)" "$file" ;;
      esac
    done )
}
files_under() { ( cd "$1" && find . -type f -not -path '*/b-agentic/backups/*' | sed 's|^\./||' | sort ); }
fresh_home() { mkdir -p "$work/$1"; printf '%s' "$work/$1"; }
# verdict <section> <candidate>: the last matching rule wins, like the permission system's own evaluation.
verdict() {
  python3 - "$perm" "$1" "$2" <<'PY'
import fnmatch
import json
import sys

rules = json.load(open(sys.argv[1]))["permission"][sys.argv[2]]
result = None
for pattern, value in rules.items():
    if fnmatch.fnmatchcase(sys.argv[3], pattern):
        result = value
print(result)
PY
}

# --- the expected file list, from the source of truth -------------------------------------------
mkdir -p "$work/rendered"
python3 -I -B "$root/tooling/generate/registry_sync.py" --render pi --out "$work/rendered/pi" >/dev/null || fail "the Pi render failed"
optional=$(jq -c '[.optional_components[].skills[]]' "$root/skills/registry.yaml")
expected="$work/expected.txt"
{
  jq -r --argjson optional "$optional" '.skills[].name | select(. as $name | $optional | index($name) | not) | "skills/\(.)/SKILL.md", "prompts/\(.).md"' "$root/skills/registry.yaml"
  (cd "$work/rendered/pi" && find agents -type f)
  printf '%s\n' AGENTS.md settings.json mcp.json extensions/pi-permission-system/config.json \
    extensions/pi-permission-classifier/config.json \
    extensions/b-agentic/index.ts extensions/b-agentic/guard.mjs \
    b-agentic/install.json b-agentic/bin/b-run b-agentic/bin/b-snapshot b-agentic/bin/b-state \
    b-agentic/hooks/b-path-guard.mjs b-agentic/hooks/b-verify-gate.mjs b-agentic/hooks/b-spec-context.mjs \
    b-agentic/hooks/b-run-context.mjs b-agentic/hooks/b-alexandria-guard.mjs \
    b-agentic/references/capabilities.yaml b-agentic/references/mcp_operations.yaml b-agentic/references/artifacts.yaml
  find "$root/claude/bin" -maxdepth 1 -type f -printf 'b-agentic/bin/%f\n' \
    | grep -E '/(b-state(-[a-z]+)?\.mjs|b-candidate-snapshot\.mjs|b-protected\.mjs|b_run\.py)$'

} | sort >"$expected"

# --- a fresh install writes exactly the expected files, and a second run writes nothing ----------
home=$(fresh_home fresh)
agent="$home/.pi/agent"
run "$home" -y; expect_ok "fresh install"
[ "$(files_under "$agent")" = "$(cat "$expected")" ] || fail "the installed files differ from the expected list: $(diff <(files_under "$agent") "$expected" | head)"
[ -z "$(find "$home" -mindepth 1 -maxdepth 1 -not -name .pi)" ] || fail "an install wrote outside ~/.pi: $(ls -A "$home")"
[ ! -e "$home/.claude" ] && [ ! -e "$home/.claude.json" ] || fail "a Pi install touched the Claude Code files"
for wrapper in b-run b-snapshot b-state; do
  [ "$(stat -c %a "$agent/b-agentic/bin/$wrapper")" = 700 ] || fail "$wrapper must be owner-executable"
done
[ -f "$agent/agents/b-worker.md" ] || fail "Pi must install b-worker.md"
while IFS=$'\t' read -r agent_name agent_model agent_thinking; do
  agent_file="$agent/agents/$agent_name.md"
  [ -f "$agent_file" ] || fail "missing installed Pi agent: $agent_file"
  frontmatter=$(awk 'NR==1{next} /^---$/{exit} {print}' "$agent_file")
  grep -Fxq "model: $agent_model" <<<"$frontmatter" || fail "$agent_name missing model: $agent_model"
  [ -z "$agent_thinking" ] || grep -Fxq "thinking: $agent_thinking" <<<"$frontmatter" \
    || fail "$agent_name missing thinking: $agent_thinking"
done < <(jq -r '(.runtimes.pi.agents + .runtimes.pi.workers) | to_entries[] | [.key, .value.model, (.value.thinking // "")] | @tsv' "$root/references/runtimes.yaml")
before=$(tree "$home")
run "$home" -y; expect_ok "second install"
[ "$before" = "$(tree "$home")" ] || fail "a second install changed files"
! grep -q 'written' <<<"$out" || fail "a second install must write nothing: $out"
grep -Fq 'unchanged' <<<"$out" || fail "a second install must report unchanged files: $out"
[ "$(jq -c '.packages' "$agent/settings.json")" = '["npm:pi-permission-classifier","npm:@gotgenes/pi-permission-system","npm:pi-subagents","npm:@juicesharp/rpiv-ask-user-question"]' ] \
  || fail "the packages must be the unpinned names with the classifier first: $(jq -c .packages "$agent/settings.json")"
[ "$(jq -c '.defaultTools' "$agent/settings.json")" = '["+grep","+find","+ls"]' ] || fail "defaultTools must add the search tools"
jq -e '.permission.skill == "allow" and .permission.subagent == "allow" and .permission.subagent_launch == "allow" and (.permission | has("codemode")) and .permission.bash["git reset --hard"] == "deny" and .permission.bash["sudo"] == "deny" and .permission.path["*.env"] == "deny" and .yoloMode == false' \
  "$agent/extensions/pi-permission-system/config.json" >/dev/null || fail "the permission config lacks a required rule"
jq -e '[.mcpServers[].exposure] | all(. == "direct")' "$agent/mcp.json" >/dev/null || fail "every MCP server must carry exposure direct"
# The classifier judges asks only when the chain names it and its own config exists; neither enables itself.
[ "$(jq -c '.authorizerChain' "$agent/extensions/pi-permission-system/config.json")" = '["permission-judge"]' ] \
  || fail "the permission config must name the classifier link in authorizerChain"
[ "$(cat "$agent/extensions/pi-permission-classifier/config.json")" = '{}' ] || fail "the classifier config must be an empty object"
! grep -Eq 'npm:[^"]*@[0-9]' "$agent/settings.json" || fail "nothing may be pinned in settings.json"
[ "$(grep -c . "$calls")" -ge 1 ] || fail "the installer never ran pi --version"
! grep -v '^pi --version offline=1$' "$calls" | grep -q . || fail "only 'pi --version' may run, with PI_OFFLINE=1: $(cat "$calls")"
[ -z "$err" ] || fail "a clean install with Pi 1.6.0 must print no warning: $err"

# --- a dry run changes nothing ---------------------------------------------------------------------
home=$(fresh_home dry)
run "$home" -y --dry-run; expect_ok "dry run"
[ -z "$(find "$home" -mindepth 1)" ] || fail "a dry run wrote files: $(find "$home" -mindepth 1 | head -3)"

# --- Pi versions: below the floor and missing warn, never fail ---------------------------------------
home=$(fresh_home old)
rc=0
out=$(env -u PI_CODING_AGENT_DIR HOME="$home" FAKE_PI_VERSION=1.5.0 PATH="$shims:$PATH" bash "$root/install.sh" --runtime=pi -y 2>"$work/stderr") || rc=$?
err=$(cat "$work/stderr")
expect_ok "install with an old pi"
grep -Fq 'below the 1.6.0 floor' <<<"$err" || fail "an old pi must warn about the floor: $err"
home=$(fresh_home missing)
rc=0
out=$(env -u PI_CODING_AGENT_DIR HOME="$home" PATH="$nopi:/usr/bin:/bin" bash "$root/install.sh" --runtime=pi -y 2>"$work/stderr") || rc=$?
err=$(cat "$work/stderr")
expect_ok "install without pi"
grep -Fq 'pi is not on PATH' <<<"$err" || fail "a missing pi must warn: $err"
grep -Fq 'never does' <<<"$err" || fail "the missing-pi warning must say the installer does not install Pi: $err"
! grep -Eq '^(npm|npx|pnpm|yarn|curl|wget) ' "$calls" || fail "a package manager or download ran: $(cat "$calls")"

# --- user files survive; conflicting rules are kept with a warning --------------------------------------
home=$(fresh_home seeded)
agent="$home/.pi/agent"
mkdir -p "$agent/extensions/pi-permission-system" "$agent/skills/mine"
printf '# mine\n' >"$agent/skills/mine/SKILL.md"
printf '%s\n' '{"theme":"dark","packages":["npm:pi-subagents@0.88.0","npm:@gotgenes/pi-permission-system","npm:pi-antigravity"],"defaultTools":["read","bash"]}' >"$agent/settings.json"
printf '%s\n' '{"authorizerChain":["my-link"],"permission":{"read":"deny","bash":{"*":"ask","ls":"allow"},"skill":"ask"},"custom":1}' >"$agent/extensions/pi-permission-system/config.json"
mkdir -p "$agent/extensions/pi-permission-classifier"
printf '%s\n' '{"mode":"quick"}' >"$agent/extensions/pi-permission-classifier/config.json"
printf '%s\n' '{"mcpServers":{"codegraph":{"command":"x"},"mine":{"command":"y"}},"other":1}' >"$agent/mcp.json"
printf '# my agents\n' >"$agent/AGENTS.md"
seeded_before=$(canonical_tree "$home")
run "$home" -y; expect_ok "install over user files"
[ "$(jq -c '.packages' "$agent/settings.json")" = '["npm:pi-subagents@0.88.0","npm:pi-permission-classifier","npm:@gotgenes/pi-permission-system","npm:pi-antigravity","npm:@juicesharp/rpiv-ask-user-question"]' ] \
  || fail "user packages must stay, with the classifier right before the permission system and subagents not duplicated: $(jq -c .packages "$agent/settings.json")"
[ "$(jq -r '.theme' "$agent/settings.json")" = dark ] || fail "a user setting was dropped"
[ "$(jq -c '.defaultTools' "$agent/settings.json")" = '["read","bash"]' ] || fail "a user's plain defaultTools list must be kept"
grep -Fq 'kept your defaultTools' <<<"$err" || fail "a kept plain defaultTools list must warn: $err"
perm="$agent/extensions/pi-permission-system/config.json"
[ "$(jq -r '.custom' "$perm")" = 1 ] && [ "$(jq -r '.permission.read' "$perm")" = deny ] && [ "$(jq -r '.permission.skill' "$perm")" = ask ] \
  && [ "$(jq -r '.permission.bash["*"]' "$perm")" = ask ] && [ "$(jq -r '.permission.bash.ls' "$perm")" = allow ] \
  || fail "a user permission rule was replaced: $(cat "$perm")"
grep -Fq 'kept your skill rule' <<<"$err" || fail "a conflicting user rule must warn: $err"
[ "$(jq -c '.authorizerChain' "$perm")" = '["my-link","permission-judge"]' ] \
  || fail "the user's authorizerChain links must stay in order with the classifier link appended: $(jq -c .authorizerChain "$perm")"
[ "$(cat "$agent/extensions/pi-permission-classifier/config.json")" = '{"mode":"quick"}' ] || fail "the user's classifier config was replaced"
[ "$(verdict bash 'sudo ls')" = deny ] || fail "the managed deny must still decide 'sudo ls' beside the user's catch-all: $(verdict bash 'sudo ls')"
[ "$(jq -r '.permission.mcp["mcp__codegraph__codegraph_explore"] // "none"' "$perm")" != allow ] || fail "a replaced MCP server must not inherit the managed automatic approvals"
[ "$(jq -c '.mcpServers.codegraph' "$agent/mcp.json")" = '{"command":"x"}' ] && [ "$(jq -r '.mcpServers.mine.command' "$agent/mcp.json")" = y ] && [ "$(jq -r '.other' "$agent/mcp.json")" = 1 ] \
  || fail "a user MCP server or key was replaced"
grep -Fq 'kept your existing MCP server' <<<"$err" || fail "a differing user MCP server must warn: $err"
[ "$(head -1 "$agent/AGENTS.md")" = '# my agents' ] || fail "the user's AGENTS.md text must stay first"
grep -Fq '<!-- b-agentic:start -->' "$agent/AGENTS.md" || fail "the kernel block must follow the user's AGENTS.md text"
[ "$(cat "$agent/skills/mine/SKILL.md")" = '# mine' ] || fail "a user skill changed"
seeded_after=$(tree "$home")
run "$home" -y; expect_ok "second install over user files"
[ "$seeded_after" = "$(tree "$home")" ] || fail "a second install over user files changed them"
# A managed file the user edited is kept with a warning, and --force replaces it after a backup.
printf 'edited\n' >>"$agent/skills/b-plan/SKILL.md"
run "$home" -y; expect_ok "install over an edited skill"
grep -Fq 'edited' "$agent/skills/b-plan/SKILL.md" || fail "an edited managed file must be kept"
grep -Fq 'modified since install' <<<"$err" || fail "an edited managed file must warn: $err"
run "$home" -y --force; expect_ok "forced install"
! grep -Fq 'edited' "$agent/skills/b-plan/SKILL.md" || fail "--force must replace an edited managed file"
[ "$(cat "$agent/extensions/pi-permission-classifier/config.json")" = '{"mode":"quick"}' ] || fail "--force must not replace the user's classifier config"
find "$agent/b-agentic/backups" -type f -name '*b-plan__SKILL.md' | grep -q . || fail "--force must back the edited file up"
# An uninstall restores exactly what the user had.
run "$home" -y --uninstall; expect_ok "uninstall over user files"
[ "$seeded_before" = "$(canonical_tree "$home")" ] || fail "uninstall did not restore the user's files: $(diff <(printf '%s\n' "$seeded_before") <(canonical_tree "$home") | head)"

# --- a fresh uninstall leaves no managed file -------------------------------------------------------------
home=$(fresh_home gone)
run "$home" -y; expect_ok "install before uninstall"
run "$home" -y --uninstall; expect_ok "uninstall"
[ ! -e "$home/.pi/agent/agents/b-worker.md" ] || fail "uninstall must remove b-worker.md"
[ -z "$(files_under "$home/.pi")" ] || fail "uninstall left files: $(files_under "$home/.pi" | head -3)"

# --- the classifier config belongs to the user once /permission-model has rewritten it --------------------
home=$(fresh_home classifier)
agent="$home/.pi/agent"
classifier_config="$agent/extensions/pi-permission-classifier/config.json"
perm="$agent/extensions/pi-permission-system/config.json"
run "$home" -y; expect_ok "install before the classifier config is edited"
printf '%s\n' '{"mode":"quick"}' >"$classifier_config"
run "$home" -y --uninstall; expect_ok "uninstall with an edited classifier config"
[ "$(cat "$classifier_config")" = '{"mode":"quick"}' ] || fail "an uninstall must keep an edited classifier config"
grep -Fq 'modified since install' <<<"$err" || fail "keeping an edited classifier config must warn: $err"
[ ! -e "$perm" ] || fail "uninstall must remove the classifier link and the permission config it created: $(cat "$perm")"
# A reinstall, even with --force, neither replaces the edited file nor takes it over: a later uninstall leaves it alone.
home=$(fresh_home classifierforced)
agent="$home/.pi/agent"
classifier_config="$agent/extensions/pi-permission-classifier/config.json"
run "$home" -y; expect_ok "install before a forced reinstall"
printf '%s\n' '{"mode":"quick"}' >"$classifier_config"
run "$home" -y --force; expect_ok "forced install over an edited classifier config"
[ "$(cat "$classifier_config")" = '{"mode":"quick"}' ] || fail "an install must never replace an edited classifier config"
run "$home" -y --uninstall; expect_ok "uninstall after a forced install"
[ "$(cat "$classifier_config")" = '{"mode":"quick"}' ] || fail "an edited classifier config must survive a forced install and an uninstall"
# A link or config the user removed after install comes back on the next install, like a rule or a package.
home=$(fresh_home restored)
agent="$home/.pi/agent"
classifier_config="$agent/extensions/pi-permission-classifier/config.json"
perm="$agent/extensions/pi-permission-system/config.json"
run "$home" -y; expect_ok "install before the classifier is switched off"
jq '.authorizerChain = []' "$perm" >"$work/perm.json" && mv "$work/perm.json" "$perm"
rm "$classifier_config"
run "$home" -y; expect_ok "install after the classifier was switched off"
[ "$(jq -c '.authorizerChain' "$perm")" = '["permission-judge"]' ] || fail "a removed classifier link must come back"
[ "$(cat "$classifier_config")" = '{}' ] || fail "a deleted classifier config must be created again"
# A `{}` the user wrote before any install is theirs: it is left alone and survives an uninstall.
home=$(fresh_home userempty)
agent="$home/.pi/agent"
classifier_config="$agent/extensions/pi-permission-classifier/config.json"
mkdir -p "$(dirname "$classifier_config")"
printf '{}\n' >"$classifier_config"
run "$home" -y; expect_ok "install beside a user's empty classifier config"
run "$home" -y --uninstall; expect_ok "uninstall beside a user's empty classifier config"
[ -f "$classifier_config" ] || fail "a classifier config the installer did not create must survive an uninstall"
# Any version spec on the permission system or the classifier (an exact pin, a range, a tag) gets neither the chain nor
# the file: Pi may load a version that rejects the key or knows only the old link name, and the installer cannot tell.
for pin in 'npm:@gotgenes/pi-permission-system@20.8.0' 'npm:@gotgenes/pi-permission-system@v20.8.0' \
  'npm:@gotgenes/pi-permission-system@~20.8.0' 'npm:@gotgenes/pi-permission-system@<20.9.0' \
  'npm:@gotgenes/pi-permission-system@^20.8.0' 'npm:@gotgenes/pi-permission-system@20.9.0' \
  'npm:pi-permission-classifier@0.5.2' 'npm:pi-permission-classifier@^0.5.2' 'npm:pi-permission-classifier@latest'; do
  home=$(fresh_home "pinned-${pin#npm:}")
  agent="$home/.pi/agent"
  mkdir -p "$agent"
  printf '{"packages":["%s"]}\n' "$pin" >"$agent/settings.json"
  run "$home" -y; expect_ok "install beside $pin"
  grep -Fq 'left authorizerChain and the classifier config alone' <<<"$err" || fail "a version spec ($pin) must warn that the classifier is left alone: $err"
  [ "$(jq -c '.authorizerChain // "none"' "$agent/extensions/pi-permission-system/config.json")" = '"none"' ] \
    || fail "no chain may be written beside $pin"
  [ ! -e "$agent/extensions/pi-permission-classifier/config.json" ] || fail "no classifier config may be written beside $pin"
  [ "$(jq -c --arg pin "$pin" '[.packages[] | select(. == $pin)] | length' "$agent/settings.json")" = 1 ] || fail "the user's pin $pin must be kept"
done
# A chain recorded by an earlier install is retired when a version spec appears, so the older package never sees it.
home=$(fresh_home pinretire)
agent="$home/.pi/agent"
run "$home" -y; expect_ok "install before a version spec appears"
jq '.packages |= map(if . == "npm:@gotgenes/pi-permission-system" then "npm:@gotgenes/pi-permission-system@20.8.0" else . end)' \
  "$agent/settings.json" >"$work/settings.json" && mv "$work/settings.json" "$agent/settings.json"
run "$home" -y; expect_ok "install after a version spec appeared"
[ "$(jq -c '.authorizerChain // "none"' "$agent/extensions/pi-permission-system/config.json")" = '"none"' ] || fail "a version spec must retire the chain"
# A chain the user left empty stays an empty array through an install and an uninstall: it blocks inherited links.
home=$(fresh_home emptychain)
agent="$home/.pi/agent"
mkdir -p "$agent/extensions/pi-permission-system"
printf '%s\n' '{"authorizerChain":[]}' >"$agent/extensions/pi-permission-system/config.json"
run "$home" -y; expect_ok "install over an empty authorizerChain"
[ "$(jq -c '.authorizerChain' "$agent/extensions/pi-permission-system/config.json")" = '["permission-judge"]' ] || fail "the link must be appended to an empty chain"
run "$home" -y --uninstall; expect_ok "uninstall over an empty authorizerChain"
[ "$(jq -c '.authorizerChain' "$agent/extensions/pi-permission-system/config.json")" = '[]' ] || fail "the user's empty authorizerChain must survive an uninstall"
# A chain retired under an older pin is no longer b-agentic's field: an empty array the user writes afterwards is theirs.
home=$(fresh_home retiredchain)
agent="$home/.pi/agent"
perm="$agent/extensions/pi-permission-system/config.json"
run "$home" -y; expect_ok "install before a pin retires the chain"
jq '.packages |= map(if . == "npm:@gotgenes/pi-permission-system" then "npm:@gotgenes/pi-permission-system@20.8.0" else . end)' \
  "$agent/settings.json" >"$work/settings.json" && mv "$work/settings.json" "$agent/settings.json"
run "$home" -y; expect_ok "install after the user pinned an older permission system"
[ "$(jq -c '.authorizerChain // "none"' "$perm")" = '"none"' ] || fail "an older pin must retire the chain"
jq '.packages |= map(sub("@20.8.0$"; ""))' "$agent/settings.json" >"$work/settings.json" && mv "$work/settings.json" "$agent/settings.json"
jq '.authorizerChain = []' "$perm" >"$work/perm.json" && mv "$work/perm.json" "$perm"
run "$home" -y; expect_ok "install after the pin was lifted over the user's empty chain"
run "$home" -y --uninstall; expect_ok "uninstall after the chain was retired and recreated"
[ "$(jq -c '.authorizerChain' "$perm")" = '[]' ] || fail "an empty chain the user wrote after a retirement must survive an uninstall"
# A classifier config replaced by a link is never b-agentic's: install keeps it, uninstall leaves the target alone.
home=$(fresh_home linkedclassifier)
agent="$home/.pi/agent"
classifier_config="$agent/extensions/pi-permission-classifier/config.json"
run "$home" -y; expect_ok "install before the classifier config becomes a link"
printf '{}\n' >"$work/dotfiles-classifier.json"
rm "$classifier_config" && ln -s "$work/dotfiles-classifier.json" "$classifier_config"
run "$home" -y; expect_ok "install beside a linked classifier config"
run "$home" -y --uninstall; expect_ok "uninstall beside a linked classifier config"
[ -f "$work/dotfiles-classifier.json" ] || fail "a linked classifier config's target must survive an uninstall"

# --- refusals happen before any write -------------------------------------------------------------------
home=$(fresh_home refused)
mkdir -p "$home/.pi/agent"
printf 'claude context\n' >"$home/.pi/agent/CLAUDE.md"
before=$(tree "$home")
run "$home" -y; expect_refused "an agent-folder CLAUDE.md"
grep -Fq 'CLAUDE.md' <<<"$err" || fail "the CLAUDE.md refusal must name the file: $err"
[ "$before" = "$(tree "$home")" ] || fail "a refused install wrote files"
rm "$home/.pi/agent/CLAUDE.md"
printf '{not json' >"$home/.pi/agent/settings.json"
before=$(tree "$home")
run "$home" -y; expect_refused "an invalid settings.json"
[ "$before" = "$(tree "$home")" ] || fail "an install refused for invalid settings.json wrote files"
rm "$home/.pi/agent/settings.json"
mkdir -p "$home/.pi/agent/extensions/pi-permission-system"
printf '%s\n' '{"authorizerChain":"permission-judge"}' >"$home/.pi/agent/extensions/pi-permission-system/config.json"
before=$(tree "$home")
run "$home" -y; expect_refused "an authorizerChain that is not an array"
grep -Fq 'authorizerChain must be an array' <<<"$err" || fail "the refusal must name authorizerChain: $err"
[ "$before" = "$(tree "$home")" ] || fail "an install refused for a bad authorizerChain wrote files"
printf '%s\n' '{"authorizerChain":null}' >"$home/.pi/agent/extensions/pi-permission-system/config.json"
before=$(tree "$home")
run "$home" -y; expect_refused "a null authorizerChain"
[ "$before" = "$(tree "$home")" ] || fail "an install refused for a null authorizerChain wrote files"
jq -n '{authorizerChain: [range(1000) | "link-\(.)"]}' >"$home/.pi/agent/extensions/pi-permission-system/config.json"
before=$(tree "$home")
run "$home" -y; expect_refused "an authorizerChain at the entry limit"
grep -Fq 'at most 1000' <<<"$err" || fail "the refusal must name the entry limit: $err"
[ "$before" = "$(tree "$home")" ] || fail "an install refused for a full authorizerChain wrote files"
rm -r "$home/.pi/agent/extensions"
rc=0
out=$(env HOME="$home" PI_CODING_AGENT_DIR="$work/elsewhere" PATH="$shims:$PATH" bash "$root/install.sh" --runtime=pi -y 2>"$work/stderr") || rc=$?
err=$(cat "$work/stderr")
expect_refused "another PI_CODING_AGENT_DIR"
run "$home" -y --statusline-only; expect_refused "--statusline-only with --runtime=pi"
run "$home" -y --uninstall --with=drawio; expect_refused "--with together with --uninstall"
rc=0
out=$(env HOME="$home" bash "$root/install.sh" --runtime=opencode 2>"$work/stderr") || rc=$?
err=$(cat "$work/stderr")
expect_refused "--runtime=opencode"
grep -Fq 'ADR-020' <<<"$err" || fail "the refusal must point to ADR-020: $err"
[ -z "$(find "$home" -mindepth 1 -not -path "$home/.pi" -not -path "$home/.pi/agent")" ] || fail "a refused run left files: $(find "$home" -mindepth 1 | head)"

# --- optional components follow --with and --without --------------------------------------------------------
home=$(fresh_home optional)
agent="$home/.pi/agent"
run "$home" -y; expect_ok "install without optional components"
[ ! -e "$agent/skills/b-drawio/SKILL.md" ] && [ "$(jq -r '.mcpServers | has("drawio")' "$agent/mcp.json")" = false ] || fail "drawio must be off by default"
run "$home" -y --with=drawio; expect_ok "install with drawio"
[ -f "$agent/skills/b-drawio/SKILL.md" ] && [ -f "$agent/prompts/b-drawio.md" ] && [ "$(jq -r '.mcpServers | has("drawio")' "$agent/mcp.json")" = true ] || fail "--with=drawio must add the skill, prompt, and MCP server"
run "$home" -y; expect_ok "rerun keeps the recorded choice"
[ -f "$agent/skills/b-drawio/SKILL.md" ] || fail "a rerun must keep the recorded optional component"
run "$home" -y --without=drawio; expect_ok "install without drawio"
[ ! -e "$agent/skills/b-drawio/SKILL.md" ] && [ "$(jq -r '.mcpServers | has("drawio")' "$agent/mcp.json")" = false ] || fail "--without=drawio must remove the skill and MCP server"

# --- a managed catch-all never overrides a rule the user wrote ------------------------------------------------
home=$(fresh_home precedence)
agent="$home/.pi/agent"
mkdir -p "$agent/extensions/pi-permission-system"
printf '%s\n' '{"permission":{"bash":{"ls*":"deny"},"path":{"*.log":"deny"},"mcp":{"mcp__mine__tool":"deny","mcp__codegraph__*":"deny"}}}' >"$agent/extensions/pi-permission-system/config.json"
run "$home" -y; expect_ok "install over user deny rules"
perm="$agent/extensions/pi-permission-system/config.json"
for section in bash path mcp; do
  [ "$(jq -r --arg s "$section" '.permission[$s] | keys_unsorted[0]' "$perm")" = '*' ] || fail "the managed catch-all of $section must come first, before user rules: $(jq -c --arg s "$section" '.permission[$s] | keys_unsorted[0:3]' "$perm")"
done
[ "$(jq -r '.permission.bash["ls*"]' "$perm")" = deny ] && [ "$(jq -r '.permission.path["*.log"]' "$perm")" = deny ] && [ "$(jq -r '.permission.mcp.mcp__mine__tool' "$perm")" = deny ] || fail "a user deny was lost"
[ "$(verdict bash 'ls -la')" = deny ] || fail "a user bash deny must still decide 'ls -la': $(verdict bash 'ls -la')"
[ "$(verdict path 'app/debug.log')" = deny ] || fail "a user path deny must still decide a log file"
[ "$(verdict mcp mcp__codegraph__codegraph_explore)" = deny ] || fail "a user MCP deny must still decide a tool the installer also lists: $(verdict mcp mcp__codegraph__codegraph_explore)"
[ "$(verdict bash 'git status')" = allow ] && [ "$(verdict bash 'sudo ls')" = deny ] || fail "the managed bash rules must still decide commands the user did not mention"
before=$(tree "$home")
run "$home" -y; expect_ok "second install over user deny rules"
[ "$before" = "$(tree "$home")" ] || fail "a second install over user deny rules changed files"

# --- a file saved while the version probe runs is merged, not overwritten ---------------------------------------
home=$(fresh_home probe-edit)
agent="$home/.pi/agent"
rc=0
out=$(env -u PI_CODING_AGENT_DIR HOME="$home" FAKE_PI_TOUCH="$agent/settings.json" PATH="$shims:$PATH" bash "$root/install.sh" --runtime=pi -y 2>"$work/stderr") || rc=$?
err=$(cat "$work/stderr")
expect_ok "install while settings.json is saved during the version probe"
[ "$(jq -r '.edited_during_probe' "$agent/settings.json")" = true ] && [ "$(jq '.packages | length' "$agent/settings.json")" -eq 4 ] || fail "a settings.json saved during the version probe was overwritten: $(cat "$agent/settings.json")"

# --- a reversed classifier and permission system order is repaired ----------------------------------------------
home=$(fresh_home reversed)
agent="$home/.pi/agent"
mkdir -p "$agent"
printf '%s\n' '{"packages":["npm:@gotgenes/pi-permission-system","npm:pi-permission-classifier@0.6.1"]}' >"$agent/settings.json"
run "$home" -y; expect_ok "install over a reversed package order"
[ "$(jq -c '.packages[0:2]' "$agent/settings.json")" = '["npm:pi-permission-classifier@0.6.1","npm:@gotgenes/pi-permission-system"]' ] || fail "the classifier must load first and keep its pin: $(jq -c .packages "$agent/settings.json")"
before=$(tree "$home")
run "$home" -y; expect_ok "second install over a repaired package order"
[ "$before" = "$(tree "$home")" ] || fail "a second install changed the repaired package order"

# --- a helper, hook, or extension file b-agentic does not own is never run through new wrappers -------------------
home=$(fresh_home stale)
agent="$home/.pi/agent"
mkdir -p "$agent/b-agentic/bin"
printf 'old helper\n' >"$agent/b-agentic/bin/b_run.py"
before=$(tree "$home")
run "$home" -y; expect_refused "an unowned helper in the way"
grep -Fq 'b_run.py' <<<"$err" || fail "the refusal must name the helper: $err"
[ "$before" = "$(tree "$home")" ] || fail "an install refused for a stale helper wrote files"
run "$home" -y --force; expect_ok "forced install over an unowned helper"
! grep -Fq 'old helper' "$agent/b-agentic/bin/b_run.py" || fail "--force must replace the unowned helper"
printf '// edited\n' >>"$agent/b-agentic/hooks/b-path-guard.mjs"
before=$(tree "$home")
run "$home" -y; expect_refused "an edited hook"
grep -Fq 'edited since install' <<<"$err" || fail "the edited-hook refusal must say it was edited: $err"
[ "$before" = "$(tree "$home")" ] || fail "an install refused for an edited hook wrote files"
run "$home" -y --uninstall; expect_ok "uninstall with an edited hook"
grep -Fq 'kept' <<<"$err" || fail "uninstall must keep the edited hook with a warning: $err"

# --- a user catch-all never cancels the managed denies and asks ------------------------------------------------------------
home=$(fresh_home catchall)
agent="$home/.pi/agent"
mkdir -p "$agent/extensions/pi-permission-system"
perm="$agent/extensions/pi-permission-system/config.json"
# The first seed is the shipped catch-all itself (no conflict, so no warning); the second is the package README's quick start.
for seed in '{"permission":{"bash":{"*":"allow"},"mcp":{"*":"allow"},"path":{"*":"allow"}}}' \
  '{"permission":{"path":{"*":"allow","*.env":"deny"},"bash":{"*":"ask","git status":"allow"},"mcp":{"*":"ask"}}}'; do
  printf '%s\n' "$seed" >"$perm"
  run "$home" -y; expect_ok "install over a user catch-all $seed"
  [ "$(verdict bash 'sudo ls')" = deny ] || fail "a user bash catch-all must not cancel the sudo deny: $(verdict bash 'sudo ls') ($seed)"
  [ "$(verdict bash 'git reset --hard')" = deny ] || fail "a user bash catch-all must not cancel the reset deny ($seed)"
  [ "$(verdict path 'certs/server.pem')" = deny ] && [ "$(verdict path 'app/secrets.yaml')" = deny ] || fail "a user path catch-all must not cancel the protected path denies ($seed)"
  [ "$(verdict mcp mcp__firecrawl__firecrawl_crawl)" = ask ] || fail "a user mcp catch-all must not cancel a managed ask ($seed)"
  [ "$(verdict bash 'git status')" != deny ] || fail "a user's specific bash rule must stay effective ($seed)"
  run "$home" -y --uninstall; expect_ok "uninstall over a user catch-all"
done
# A stricter user catch-all is a floor: managed allows and asks that are looser than it are not installed.
printf '%s\n' '{"permission":{"bash":{"*":"deny","git status":"allow"},"mcp":{"*":"deny"},"path":{"*":"deny"}}}' >"$perm"
run "$home" -y; expect_ok "install over a deny catch-all"
grep -Fq 'is stricter than b-agentic' <<<"$err" || fail "a stricter user catch-all must be reported: $err"
[ "$(verdict mcp mcp__playwright__browser_click)" = deny ] && [ "$(verdict mcp mcp__codegraph__codegraph_explore)" = deny ] || fail "a user mcp deny catch-all must not be loosened by managed allows"
[ "$(verdict bash 'gh pr create')" = deny ] && [ "$(verdict bash 'git push origin feature')" = deny ] && [ "$(verdict bash 'sudo ls')" = deny ] || fail "a user bash deny catch-all must not be loosened by managed asks"
[ "$(verdict path 'a/.env.example')" = deny ] && [ "$(verdict path 'a/server.pem')" = deny ] || fail "a user path deny catch-all must not be loosened by managed allows"
[ "$(verdict bash 'git status')" = allow ] || fail "a specific user allow must stay effective under the user's own catch-all"
before=$(tree "$home")
run "$home" -y; expect_ok "second install over a deny catch-all"
[ "$before" = "$(tree "$home")" ] || fail "a second install over a deny catch-all changed files"
run "$home" -y --uninstall; expect_ok "uninstall over a deny catch-all"
[ "$(jq -cS . "$perm")" = '{"permission":{"bash":{"*":"deny","git status":"allow"},"mcp":{"*":"deny"},"path":{"*":"deny"}}}' ] || fail "uninstall must restore the user's deny catch-all config: $(cat "$perm")"
# A user catch-all that is not their first rule keeps its place: rules written before it stay shadowed by it.
printf '%s\n' '{"permission":{"bash":{"git push *":"allow","*":"ask"},"path":{"*":"ask"}}}' >"$perm"
before_perm=$(jq -c . "$perm")
run "$home" -y; expect_ok "install over a catch-all that is not first"
[ "$(verdict bash 'git push origin x')" = ask ] || fail "a user rule written before their catch-all must stay shadowed by it: $(verdict bash 'git push origin x')"
[ "$(verdict bash 'sudo ls')" = deny ] || fail "the managed deny must still decide after a user catch-all that is not first"
[ "$(verdict path 'a/.env.example')" != allow ] || fail "an ask path catch-all must drop the managed path allow"
[ "$(verdict path 'a/notes.txt')" = ask ] || fail "an ask path catch-all must decide an ordinary file: $(verdict path 'a/notes.txt')"
before=$(tree "$home")
run "$home" -y; expect_ok "second install over a catch-all that is not first"
[ "$before" = "$(tree "$home")" ] || fail "a second install over a catch-all that is not first changed files"
run "$home" -y --uninstall; expect_ok "uninstall over a catch-all that is not first"
[ "$(jq -c . "$perm")" = "$before_perm" ] || fail "uninstall must restore the user's rules in their own order: $(jq -c . "$perm")"
# A catch-all the user edits after installing is a floor on the next run, and setting it back restores the managed rules.
printf '%s\n' '{}' >"$perm"
run "$home" -y; expect_ok "install over an empty permission config"
jq '.permission.bash["*"] = "deny"' "$perm" >"$work/perm.json" && mv "$work/perm.json" "$perm"
run "$home" -y; expect_ok "reinstall after the user tightened the managed catch-all"
[ "$(verdict bash 'gh pr create')" = deny ] || fail "a managed catch-all the user tightened must become a floor"
jq '.permission.bash["*"] = "allow"' "$perm" >"$work/perm.json" && mv "$work/perm.json" "$perm"
run "$home" -y; expect_ok "reinstall after the user restored the shipped catch-all"
[ "$(verdict bash 'gh pr create')" = ask ] || fail "the managed asks must return once the catch-all is the shipped one again"
run "$home" -y --uninstall; expect_ok "uninstall after the catch-all edits"
# An object where a verdict belongs is refused with a clear message before any write.
printf '%s\n' '{"permission":{"bash":{"*":{"deny":true}}}}' >"$perm"
before=$(tree "$home")
run "$home" -y; expect_refused "a catch-all that is not a verdict"
grep -Fq 'must be allow, ask, or deny' <<<"$err" || fail "the refusal must say what a catch-all may be: $err"
[ "$before" = "$(tree "$home")" ] || fail "an install refused for a bad catch-all wrote files"
# A single-value section is refused with the form to write, before any write.
printf '%s\n' '{"permission":{"bash":"ask"}}' >"$perm"
before=$(tree "$home")
run "$home" -y; expect_refused "a permission section written as a single value"
grep -Fq '{"*": "ask"}' <<<"$err" || fail "the refusal must show the object form to write: $err"
[ "$before" = "$(tree "$home")" ] || fail "an install refused for a single-value section wrote files"

# --- an explicit empty defaultTools list and a disabled permission extension are the user's to resolve ------------
home=$(fresh_home emptytools)
agent="$home/.pi/agent"
mkdir -p "$agent"
printf '%s\n' '{"defaultTools":[]}' >"$agent/settings.json"
run "$home" -y; expect_ok "install over an empty defaultTools list"
[ "$(jq -c '.defaultTools' "$agent/settings.json")" = '[]' ] || fail "an explicit empty defaultTools list must stay empty: $(jq -c .defaultTools "$agent/settings.json")"
grep -Fq 'kept your defaultTools' <<<"$err" || fail "a kept empty defaultTools list must warn: $err"
home=$(fresh_home disabled)
agent="$home/.pi/agent"
mkdir -p "$agent"
printf '%s\n' '{"packages":[{"source":"npm:@gotgenes/pi-permission-system","extensions":[]}]}' >"$agent/settings.json"
before=$(tree "$home")
run "$home" -y; expect_refused "a permission system package with its extensions disabled"
grep -Fq 'filters the extensions' <<<"$err" || fail "the refusal must name the package filter: $err"
[ "$before" = "$(tree "$home")" ] || fail "an install refused for a disabled permission extension wrote files"

for filtered in '{"source":"npm:@gotgenes/pi-permission-system","autoload":false}' '{"source":"npm:@gotgenes/pi-permission-system","extensions":["!extensions/main.ts"]}'; do
  printf '{"packages":[%s]}\n' "$filtered" >"$agent/settings.json"
  before=$(tree "$home")
  run "$home" -y; expect_refused "a filtered permission system package $filtered"
  [ "$before" = "$(tree "$home")" ] || fail "an install refused for a filtered permission extension wrote files"
done

# --- a reinstall restores a removed managed catch-all in front of the managed denies ------------------------------
home=$(fresh_home reorder)
agent="$home/.pi/agent"
run "$home" -y; expect_ok "install before removing a catch-all"
perm="$agent/extensions/pi-permission-system/config.json"
jq 'del(.permission.bash["*"], .permission.path["*"], .permission.mcp["*"])' "$perm" >"$work/perm.json" && mv "$work/perm.json" "$perm"
run "$home" -y; expect_ok "reinstall after removing the catch-alls"
for section in bash path mcp; do
  [ "$(jq -r --arg s "$section" '.permission[$s] | keys_unsorted[0]' "$perm")" = '*' ] || fail "a restored catch-all of $section must go first"
done
[ "$(verdict bash 'git pull')" = deny ] || fail "the managed git pull deny must decide after a catch-all is restored: $(verdict bash 'git pull')"

# --- uninstall through a config symlink never prunes folders outside the agent directory --------------------------
home=$(fresh_home linked)
agent="$home/.pi/agent"
mkdir -p "$agent" "$work/external/deep"
ln -s "$work/external/deep/settings-target.json" "$agent/settings.json"
run "$home" -y; expect_ok "install through a dangling settings.json link"
[ -f "$work/external/deep/settings-target.json" ] || fail "the install must write through the user's link"
run "$home" -y --uninstall; expect_ok "uninstall through a dangling settings.json link"
[ -d "$work/external/deep" ] || fail "uninstall pruned a folder outside the agent directory"

# --- a failed policy write leaves settings.json unpublished -------------------------------------------------------
home=$(fresh_home policyfail)
agent="$home/.pi/agent"
mkdir -p "$agent/extensions/pi-permission-system"
chmod 555 "$agent/extensions/pi-permission-system"
run "$home" -y; expect_refused "an install whose permission config cannot be written"
[ ! -e "$agent/settings.json" ] || fail "settings.json was published although the permission config could not be written"
chmod 755 "$agent/extensions/pi-permission-system"
run "$home" -y; expect_ok "a retry after the permission config became writable"
[ -f "$agent/settings.json" ] && [ -f "$agent/extensions/pi-permission-system/config.json" ] || fail "the retry must complete the install"

# --- a config link into Pi's own state is refused before any read or write --------------------------------------------
home=$(fresh_home authlink)
agent="$home/.pi/agent"
mkdir -p "$agent"
printf '{"synthetic":"credential"}\n' >"$agent/auth.json"
ln -s auth.json "$agent/AGENTS.md"
before=$(tree "$home")
run "$home" -y; expect_refused "an AGENTS.md link to auth.json"
[ "$before" = "$(tree "$home")" ] || fail "an install refused for an auth.json link changed files"
[ ! -e "$agent/b-agentic/backups" ] || fail "the refused install backed Pi's own state up"
rm "$agent/AGENTS.md"
mkdir -p "$work/dotfiles"
printf '{"synthetic":"credential"}\n' >"$work/dotfiles/auth.json"
ln -s "$work/dotfiles/auth.json" "$agent/settings.json"
run "$home" -y; expect_refused "a settings.json link to a file named auth.json outside the agent directory"
[ "$(cat "$work/dotfiles/auth.json")" = '{"synthetic":"credential"}' ] || fail "the linked auth.json changed"

# --- servers outside the shipped template get no automatic approvals ------------------------------------------------------
home=$(fresh_home datagrip)
agent="$home/.pi/agent"
mkdir -p "$agent"
printf '%s\n' '{"mcpServers":{"datagrip":{"command":"my-datagrip"}}}' >"$agent/mcp.json"
run "$home" -y --with=datagrip; expect_ok "install with datagrip over a user-managed endpoint"
perm="$agent/extensions/pi-permission-system/config.json"
[ "$(jq -r '.permission.mcp["mcp__datagrip__list_database_connections"] // "none"' "$perm")" != allow ] || fail "a user-managed DataGrip endpoint must get no automatic approvals"
[ "$(jq -r '.permission.mcp["mcp__codegraph__codegraph_explore"]' "$perm")" = allow ] || fail "an installed server must keep its automatic approval"
[ "$(jq -c '.mcpServers.datagrip' "$agent/mcp.json")" = '{"command":"my-datagrip"}' ] || fail "the user's DataGrip endpoint changed"

# --- the Pi install never reaches the network for its source or follows an agent root into ~/.claude ---------------
gitshim="$work/gitshim"
mkdir -p "$gitshim"
printf '#!/bin/sh\necho "git $*" >>"%s"\nexit 1\n' "$calls" >"$gitshim/git"
chmod +x "$gitshim/git"
home=$(fresh_home nonet)
: >"$calls"
for flag in --update --ref=main; do
  rc=0
  out=$(env -u PI_CODING_AGENT_DIR HOME="$home" PATH="$gitshim:$PATH" bash "$root/install.sh" --runtime=pi -y "$flag" 2>"$work/stderr") || rc=$?
  expect_refused "--runtime=pi $flag"
done
rc=0
out=$(env -u PI_CODING_AGENT_DIR HOME="$home" B_AGENTIC_DIR="$work/clone" PATH="$gitshim:$PATH" bash -s -- --runtime=pi -y <"$root/install.sh" 2>"$work/stderr") || rc=$?
err=$(cat "$work/stderr")
expect_refused "a piped --runtime=pi install"
grep -Fq 'never clones' <<<"$err" || fail "a piped Pi install must refuse to clone: $err"
[ ! -s "$calls" ] && [ ! -e "$work/clone" ] || fail "a refused Pi bootstrap reached git: $(cat "$calls")"
[ -z "$(find "$home" -mindepth 1)" ] || fail "a refused Pi bootstrap wrote files"
home=$(fresh_home rooted)
mkdir -p "$home/.claude" "$home/.pi"
ln -s "$home/.claude" "$home/.pi/agent"
before=$(tree "$home")
run "$home" -y; expect_refused "an agent root that resolves into ~/.claude"
[ "$before" = "$(tree "$home")" ] || fail "an install through a link into ~/.claude wrote files"

# --- the wrappers name the Pi folder and take the Pi session as the lock owner ---------------------------------
home=$(fresh_home wrappers)
agent="$home/.pi/agent"
run "$home" -y; expect_ok "install for the wrapper check"
repo="$work/repo"
mkdir -p "$repo"
git -C "$repo" init -q .
git -C "$repo" config user.email probe@example.invalid
git -C "$repo" config user.name probe
printf 'a\n' >"$repo/a.txt"
git -C "$repo" add .
git -C "$repo" commit -qm init
wrap() { env HOME="$home" PI_SESSION_ID=pi-probe-1 CLAUDE_CODE_SESSION_ID=claude-probe-1 PATH="$PATH" "$agent/b-agentic/bin/$1" "${@:2}"; }
[ "$(wrap b-state help | head -1)" = 'Usage: ~/.pi/agent/b-agentic/bin/b-state <command> [args] [--run ID] [--owner NAME]' ] || fail "b-state usage must name the Pi folder: $(wrap b-state help | head -1)"
# shellcheck disable=SC2088 # The helpers print the folder as the literal text ~/..., never expanded.
wrap b-run help | grep -Fq '~/.pi/agent/b-agentic/bin/b-run' || fail "b-run usage must name the Pi folder"
[ -n "$(cd "$repo" && wrap b-snapshot --fingerprint)" ] || fail "the b-snapshot wrapper must print a fingerprint in a repository"
(cd "$repo" && wrap b-state init pi-wrapper-check >/dev/null) || fail "b-state init through the wrapper failed"
lock=$(find "$repo/.b-agentic" -name lock | head -1)
[ -n "$lock" ] && [ "$(jq -r .owner "$lock")" = pi-probe-1 ] || fail "the lock owner must be the PI_SESSION_ID value: $(cat "$lock" 2>/dev/null)"

echo "pi install probe passed"
