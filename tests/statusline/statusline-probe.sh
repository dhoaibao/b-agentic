#!/usr/bin/env bash
# Exercise claude/bin/b-statusline.mjs with scripted status JSON.
# Needs only bun and jq: no network, credentials, or Claude Code.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
cli="$root/claude/bin/b-statusline.mjs"
# Claude Code runs the status line with bun and the same hardening flags the installer writes (ADR-018).
js=(bun --no-env-file --config=/dev/null)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

fail() { echo "statusline probe failed: $*" >&2; exit 1; }
plain() { sed 's/\x1b\[[0-9;]*m//g'; }

now=$(date +%s)

# Full input: model, effort, context, both limits, and no cache or repo fields.
jq -nc --argjson r $((now + 5000)) --argjson w $((now + 200000)) '{
  model: {display_name: "Opus"}, effort: {level: "high"},
  context_window: {used_percentage: 55.4, context_window_size: 1000000,
    current_usage: {input_tokens: 10, cache_read_input_tokens: 554000}},
  rate_limits: {five_hour: {used_percentage: 12, resets_at: $r}, seven_day: {used_percentage: 85, resets_at: $w}}}' >"$work/full.json"
raw=$("${js[@]}" "$cli" <"$work/full.json")
line=$(plain <<<"$raw")
[ "$line" = "Opus · high   context 55% (554k/1M)   5h 12% · 1h 23m   week 85% · 2d 7h" ] || fail "full line: $line"
grep -Fq $'\033[31m85%' <<<"$raw" || fail "85% must be red"
grep -Fq $'\033[33m55%' <<<"$raw" || fail "55% must be yellow"
grep -Fq $'\033[32m12%' <<<"$raw" || fail "12% must be green"

# Repo and branch, session cost, and cache hit ratio. The branch is read from .git/HEAD,
# including a worktree's `.git` file and a detached HEAD.
mkdir -p "$work/repo/.git" "$work/repo/sub" "$work/wt-gitdir" "$work/wt" "$work/detached/.git"
printf 'ref: refs/heads/feat/x\n' >"$work/repo/.git/HEAD"
printf 'ref: refs/heads/wt-branch\n' >"$work/wt-gitdir/HEAD"
printf 'gitdir: %s\n' "$work/wt-gitdir" >"$work/wt/.git"
printf '0123456789abcdef0123456789abcdef01234567\n' >"$work/detached/.git/HEAD"
meta() { jq -c --arg d "$1" '.workspace = {current_dir: $d, repo: {name: "demo"}} | .cost = {total_cost_usd: 1.183}
  | .prompt_cache = {expires_at: 1, hit_ratio: 0.9006}' "$work/full.json" | "${js[@]}" "$cli" | plain; }
raw=$(meta "$work/repo/sub")
[ "$raw" = "Opus · high   demo@feat/x   context 55% (554k/1M)   \$1.18   cache 90% hit   5h 12% · 1h 23m   week 85% · 2d 7h" ] || fail "meta line: $raw"
grep -Fq 'demo@wt-branch' <<<"$(meta "$work/wt")" || fail "worktree branch"
grep -Fq 'demo@0123456 ' <<<"$(meta "$work/detached")" || fail "detached HEAD short sha"
grep -Fq 'demo ' <<<"$(meta "$work/none")" || fail "repo name without a repository"

# The cache segment shows only the hit ratio, never an expiry countdown, and only when reported.
raw=$(jq -c --argjson e $((now + 600)) '.prompt_cache = {expires_at: $e, hit_ratio: 0.5}' "$work/full.json" | "${js[@]}" "$cli" | plain)
grep -Fq 'cache 50% hit' <<<"$raw" || fail "hit ratio not shown: $raw"
# A high hit ratio is good, so the colours run the other way from the usage percents.
hit_raw() { jq -c --argjson h "$1" '.prompt_cache = {hit_ratio: $h}' "$work/full.json" | "${js[@]}" "$cli"; }
grep -Fq $'\033[32m90%' <<<"$(hit_raw 0.9)" || fail "90% hit must be green"
grep -Fq $'\033[33m60%' <<<"$(hit_raw 0.6)" || fail "60% hit must be yellow"
grep -Fq $'\033[31m20%' <<<"$(hit_raw 0.2)" || fail "20% hit must be red"
grep -Eq 'exp\.|cache [0-9]+m' <<<"$raw" && fail "cache expiry must not be shown: $raw"
raw=$(jq -c '.prompt_cache = {expires_at: null}' "$work/full.json" | "${js[@]}" "$cli" | plain)
grep -Fq 'cache' <<<"$raw" && fail "no hit ratio must show no cache segment: $raw"

# Compaction hint: shown only where a b-flow run is recorded, chosen from the run phase and the context size.
run_dir() { # name, phase: a project with a recorded run in that phase
  mkdir -p "$work/$1/.b-agentic/runs/20261118-r1" "$work/$1/sub"
  printf '20261118-r1\n' >"$work/$1/.b-agentic/active"
  jq -nc --arg p "$2" '{run_id: "20261118-r1", phase: $p, other: "text that must never be printed"}' >"$work/$1/.b-agentic/runs/20261118-r1/state.json"
  printf '{"owner":"sess-1","at":"2026-11-18T00:00:00.000Z"}\n' >"$work/$1/.b-agentic/runs/20261118-r1/lock"
}
# stock macOS has no GNU timeout; the alarm survives exec and bounds the command the same way
bounded() { # bounded <seconds> <command...>
  if command -v timeout >/dev/null 2>&1; then timeout "$@"
  elif command -v gtimeout >/dev/null 2>&1; then gtimeout "$@"
  else perl -e 'alarm shift; exec @ARGV or die "exec: $!\n"' "$@"
  fi
}
hint_line() { # project name, used tokens, used percent, optional session id (default sess-1, the lock owner)
  jq -c --arg d "$work/$1/sub" --argjson u "$2" --argjson p "$3" --arg s "${4-sess-1}" '.workspace = {current_dir: $d}
    | .context_window = {used_percentage: $p, context_window_size: 1000000, current_usage: {input_tokens: $u}}
    | if $s == "" then del(.session_id) else .session_id = $s end' "$work/full.json" | bounded 10 "${js[@]}" "$cli" | plain
}
run_dir hint-done "done"
run_dir hint-approved approved
run_dir hint-implement implement
run_dir hint-blocked blocked
grep -Fq 'run done: /compact or /clear' <<<"$(hint_line hint-done 620000 62)" || fail "a done run at 620k must hint to compact or clear"
grep -Fq 'run done:' <<<"$(hint_line hint-done 150000 15)" && fail "a done run under 200k must not hint"
grep -Fq 'plan on disk: /compact before implement' <<<"$(hint_line hint-approved 250000 25)" || fail "an approved run at 250k must hint"
grep -Fq 'near auto-compact' <<<"$(hint_line hint-implement 820000 82)" || fail "an implement run at 82% must warn"
grep -Fq 'near auto-compact' <<<"$(hint_line hint-blocked 900000 90)" || fail "a blocked run at 90% must warn"
grep -Eq 'run done|plan on disk|near auto-compact' <<<"$(hint_line hint-implement 550000 55)" && fail "a mid-run phase at 55% must not hint"
# A finished or just-approved run counts only in the session that holds its lock; the 80% warning needs no session.
grep -Fq 'run done' <<<"$(hint_line hint-done 620000 62 sess-2)" && fail "a done run must not hint in another session"
grep -Fq 'plan on disk' <<<"$(hint_line hint-approved 250000 25 sess-2)" && fail "an approved run must not hint in another session"
grep -Fq 'run done' <<<"$(hint_line hint-done 620000 62 '')" && fail "a done run must not hint without a session id"
grep -Fq 'near auto-compact' <<<"$(hint_line hint-implement 820000 82 sess-2)" || fail "the 80% warning must show in any session"
# Above 80% the near-limit warning stays for both phases whatever the session check says, without the run-specific text.
for p in hint-done hint-approved; do
  for s in sess-2 ''; do
    out=$(hint_line "$p" 820000 82 "$s")
    grep -Fq 'near auto-compact: /compact soon' <<<"$out" || fail "$p in session '$s' at 82% must still warn: $out"
    grep -Eq 'run done|plan on disk|finish this phase' <<<"$out" && fail "$p in session '$s' must not show run-specific text: $out"
  done
done
run_dir hint-nolock "done"
rm -f "$work/hint-nolock/.b-agentic/runs/20261118-r1/lock"
grep -Fq 'run done' <<<"$(hint_line hint-nolock 620000 62)" && fail "a done run without a lock must not hint"
grep -Fq 'near auto-compact: /compact soon' <<<"$(hint_line hint-nolock 820000 82)" || fail "a done run without a lock must still warn at 82%"
run_dir hint-badlock "done"
printf 'not json' >"$work/hint-badlock/.b-agentic/runs/20261118-r1/lock"
grep -Fq 'run done' <<<"$(hint_line hint-badlock 620000 62)" && fail "a done run with an unreadable lock must not hint"
grep -Fq 'near auto-compact: /compact soon' <<<"$(hint_line hint-badlock 820000 82)" || fail "a done run with an unreadable lock must still warn at 82%"
run_dir hint-locklink "done"
mv "$work/hint-locklink/.b-agentic/runs/20261118-r1/lock" "$work/hint-locklink/real-lock"
ln -s "$work/hint-locklink/real-lock" "$work/hint-locklink/.b-agentic/runs/20261118-r1/lock"
grep -Fq 'run done' <<<"$(hint_line hint-locklink 620000 62)" && fail "a symlinked lock must not be followed"
grep -Fq 'text that must never be printed' <<<"$(hint_line hint-done 620000 62)" && fail "run state text must never reach the line"
# Without run state, with a corrupt state, or with an unknown phase the line is unchanged.
mkdir -p "$work/hint-none/sub"
[ "$(hint_line hint-none 620000 62)" = "$(jq -c --arg d "$work/hint-none/sub" '.workspace = {current_dir: $d}
  | .context_window = {used_percentage: 62, context_window_size: 1000000, current_usage: {input_tokens: 620000}}' "$work/full.json" | "${js[@]}" "$cli" | plain)" ] || fail "no active file"
grep -Eq 'run done|plan on disk|near auto-compact' <<<"$(hint_line hint-none 900000 90)" && fail "a project without run state must not hint"
run_dir hint-corrupt "done"
printf 'not json' >"$work/hint-corrupt/.b-agentic/runs/20261118-r1/state.json"
grep -Eq 'run done|plan on disk|near auto-compact' <<<"$(hint_line hint-corrupt 900000 90)" && fail "a corrupt state must not hint"
run_dir hint-unknown nonsense
grep -Eq 'run done|plan on disk|near auto-compact' <<<"$(hint_line hint-unknown 900000 90)" && fail "an unknown phase must not hint"
run_dir hint-badid "done"
printf '../../etc\n' >"$work/hint-badid/.b-agentic/active"
grep -Eq 'run done|plan on disk|near auto-compact' <<<"$(hint_line hint-badid 900000 90)" && fail "an active id with path characters must not be followed"
# Run files are untrusted: a FIFO, a symlink, or an oversized file never stalls the line or yields a hint.
run_dir hint-fifo "done"
rm -f "$work/hint-fifo/.b-agentic/active"
mkfifo "$work/hint-fifo/.b-agentic/active"
out=$(hint_line hint-fifo 900000 90) || fail "a FIFO as the active pointer must not stall the status line"
grep -Fq 'context 90%' <<<"$out" || fail "the line must still print with a FIFO pointer: $out"
grep -Eq 'run done|plan on disk|near auto-compact' <<<"$out" && fail "a FIFO pointer must not hint"
run_dir hint-link "done"
printf '20261118-r1\n' >"$work/hint-link/real-active"
rm -f "$work/hint-link/.b-agentic/active"
ln -s "$work/hint-link/real-active" "$work/hint-link/.b-agentic/active"
grep -Eq 'run done|plan on disk|near auto-compact' <<<"$(hint_line hint-link 900000 90)" && fail "a symlinked active pointer must not be followed"
run_dir hint-big "done"
head -c 300000 /dev/zero | tr '\0' ' ' >"$work/hint-big/.b-agentic/runs/20261118-r1/state.json"
grep -Eq 'run done|plan on disk|near auto-compact' <<<"$(hint_line hint-big 900000 90)" && fail "an oversized state file must not be read"
# The pointer lives at the worktree root: a nested repository never borrows an enclosing project's run.
run_dir hint-outer "done"
mkdir -p "$work/hint-outer/nested/.git" "$work/hint-outer/nested/deep"
grep -Eq 'run done' <<<"$(jq -c --arg d "$work/hint-outer/nested/deep" '.workspace = {current_dir: $d} | .session_id = "sess-1"
  | .context_window = {used_percentage: 90, context_window_size: 1000000, current_usage: {input_tokens: 900000}}' "$work/full.json" | "${js[@]}" "$cli" | plain)" && fail "a nested repository must not inherit the enclosing run"
mkdir -p "$work/hint-outer/nested/.b-agentic/runs/20261118-n1"
printf '20261118-n1\n' >"$work/hint-outer/nested/.b-agentic/active"
printf '{"run_id":"20261118-n1","phase":"approved"}' >"$work/hint-outer/nested/.b-agentic/runs/20261118-n1/state.json"
printf '{"owner":"sess-1"}\n' >"$work/hint-outer/nested/.b-agentic/runs/20261118-n1/lock"
grep -Fq 'plan on disk' <<<"$(jq -c --arg d "$work/hint-outer/nested/deep" '.workspace = {current_dir: $d} | .session_id = "sess-1"
  | .context_window = {used_percentage: 30, context_window_size: 1000000, current_usage: {input_tokens: 300000}}' "$work/full.json" | "${js[@]}" "$cli" | plain)" || fail "a nested repository must use its own run"
# A run folder must be a real directory of the same project and carry the id the pointer names.
run_dir hint-mismatch "done"
jq -nc '{run_id: "20261118-other", phase: "done"}' >"$work/hint-mismatch/.b-agentic/runs/20261118-r1/state.json"
grep -Eq 'run done|plan on disk|near auto-compact' <<<"$(hint_line hint-mismatch 900000 90)" && fail "a state whose run_id differs from the pointer must not hint"
run_dir hint-linkdir "done"
mv "$work/hint-linkdir/.b-agentic/runs/20261118-r1" "$work/hint-linkdir/elsewhere"
ln -s "$work/hint-linkdir/elsewhere" "$work/hint-linkdir/.b-agentic/runs/20261118-r1"
grep -Eq 'run done|plan on disk|near auto-compact' <<<"$(hint_line hint-linkdir 900000 90)" && fail "a symlinked run folder must not be followed"
run_dir hint-linkruns "done"
mv "$work/hint-linkruns/.b-agentic/runs" "$work/hint-linkruns/real-runs"
ln -s "$work/hint-linkruns/real-runs" "$work/hint-linkruns/.b-agentic/runs"
grep -Eq 'run done|plan on disk|near auto-compact' <<<"$(hint_line hint-linkruns 900000 90)" && fail "a symlinked runs directory must not be followed"
run_dir hint-linkbase "done"
mv "$work/hint-linkbase/.b-agentic" "$work/hint-linkbase/real-b-agentic"
ln -s "$work/hint-linkbase/real-b-agentic" "$work/hint-linkbase/.b-agentic"
grep -Eq 'run done|plan on disk|near auto-compact' <<<"$(hint_line hint-linkbase 900000 90)" && fail "a symlinked .b-agentic must not be followed"
# The copied phase list must stay equal to the state helper's.
[ "$("${js[@]}" -e 'import { RUN_PHASES } from "'"$cli"'"; import { PHASES } from "'"$root"'/claude/bin/b-state-core.mjs"; console.log(JSON.stringify(RUN_PHASES) === JSON.stringify(PHASES))')" = true ] || fail "the status line phase list must equal the b-state phase list"

# Every copy of the run id pattern must stay equal to the state helper's.
[ "$("${js[@]}" -e 'import { readFileSync } from "node:fs"; import { RUN_ID as a } from "'"$cli"'"; import { RUN_ID as core } from "'"$root"'/claude/bin/b-state-core.mjs";
const hook = readFileSync("'"$root"'/claude/hooks/b-run-context.mjs", "utf8").match(/const RUN_ID = \/(.+)\/;/)?.[1];
const py = readFileSync("'"$root"'/claude/bin/b_run.py", "utf8").match(/^RUN_ID = re\.compile\(r"(.+)"\)$/m)?.[1];
console.log([a.source, hook, py].every((source) => source === core.source))')" = true ] || fail "every RUN_ID copy must equal the b-state run id pattern"

# A valid state the writer accepts (up to 1 MiB) must still read; a larger file is dropped.
run_dir hint-big "done"
jq -nc '{run_id: "20261118-r1", phase: "done", pad: ("x" * 300000)}' >"$work/hint-big/.b-agentic/runs/20261118-r1/state.json"
grep -Fq 'run done: /compact or /clear' <<<"$(hint_line hint-big 620000 62)" || fail "a 300 KB valid state must still hint"
run_dir hint-huge "done"
jq -nc '{run_id: "20261118-r1", phase: "done", pad: ("x" * 1100000)}' >"$work/hint-huge/.b-agentic/runs/20261118-r1/state.json"
grep -Eq 'run done|plan on disk|near auto-compact' <<<"$(hint_line hint-huge 900000 90)" && fail "a state over 1 MiB must not hint"

# Missing fields and invalid input never crash or print noise.
[ -z "$(printf '{}' | "${js[@]}" "$cli" | plain | tr -d '\n')" ] || fail "empty input must print an empty line"
[ "$(printf '{"model":{"display_name":"Sonnet"}}' | "${js[@]}" "$cli" | plain)" = "Sonnet" ] || fail "model only"
[ -z "$(printf 'not json' | "${js[@]}" "$cli")" ] || fail "invalid input must print nothing"

# A reader never writes: the run leaves the work directory unchanged.
before=$(find "$work" -type f | sort | xargs sha256sum)
"${js[@]}" "$cli" <"$work/full.json" >/dev/null
[ "$before" = "$(find "$work" -type f | sort | xargs sha256sum)" ] || fail "the status line wrote a file"
echo "statusline probe passed"
