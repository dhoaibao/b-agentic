#!/usr/bin/env bash
# Exercise claude/bin/b-statusline.mjs with scripted status JSON.
# Needs only node and jq: no network, credentials, or Claude Code.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
cli="$root/claude/bin/b-statusline.mjs"
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
raw=$(node "$cli" <"$work/full.json")
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
  | .prompt_cache = {expires_at: 1, hit_ratio: 0.9006}' "$work/full.json" | node "$cli" | plain; }
raw=$(meta "$work/repo/sub")
[ "$raw" = "Opus · high   demo@feat/x   context 55% (554k/1M)   \$1.18   cache 90% hit   5h 12% · 1h 23m   week 85% · 2d 7h" ] || fail "meta line: $raw"
grep -Fq 'demo@wt-branch' <<<"$(meta "$work/wt")" || fail "worktree branch"
grep -Fq 'demo@0123456 ' <<<"$(meta "$work/detached")" || fail "detached HEAD short sha"
grep -Fq 'demo ' <<<"$(meta "$work/none")" || fail "repo name without a repository"

# The cache segment shows only the hit ratio, never an expiry countdown, and only when reported.
raw=$(jq -c --argjson e $((now + 600)) '.prompt_cache = {expires_at: $e, hit_ratio: 0.5}' "$work/full.json" | node "$cli" | plain)
grep -Fq 'cache 50% hit' <<<"$raw" || fail "hit ratio not shown: $raw"
grep -Eq 'exp\.|cache [0-9]+m' <<<"$raw" && fail "cache expiry must not be shown: $raw"
raw=$(jq -c '.prompt_cache = {expires_at: null}' "$work/full.json" | node "$cli" | plain)
grep -Fq 'cache' <<<"$raw" && fail "no hit ratio must show no cache segment: $raw"

# Missing fields and invalid input never crash or print noise.
[ -z "$(printf '{}' | node "$cli" | plain | tr -d '\n')" ] || fail "empty input must print an empty line"
[ "$(printf '{"model":{"display_name":"Sonnet"}}' | node "$cli" | plain)" = "Sonnet" ] || fail "model only"
[ -z "$(printf 'not json' | node "$cli")" ] || fail "invalid input must print nothing"

# A reader never writes: the run leaves the work directory unchanged.
before=$(find "$work" -type f | sort | xargs sha256sum)
node "$cli" <"$work/full.json" >/dev/null
[ "$before" = "$(find "$work" -type f | sort | xargs sha256sum)" ] || fail "the status line wrote a file"
echo "statusline probe passed"
