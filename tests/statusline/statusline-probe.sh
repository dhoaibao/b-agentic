#!/usr/bin/env bash
# Exercise claude/bin/b-statusline.mjs with scripted status JSON and transcripts.
# Needs only node and jq: no network, credentials, or Claude Code.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
cli="$root/claude/bin/b-statusline.mjs"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

fail() { echo "statusline probe failed: $*" >&2; exit 1; }
plain() { sed 's/\x1b\[[0-9;]*m//g'; }

now=$(date +%s)
stamp() { node -e 'console.log(new Date(Number(process.argv[1]) * 1000).toISOString())' "$1"; }

# Full input: model, effort, context, a live 1h cache, and both limits.
printf '{"type":"assistant","timestamp":"%s","message":{"usage":{"cache_creation":{"ephemeral_1h_input_tokens":10}}}}\n' \
  "$(stamp $((now - 120)))" >"$work/live.jsonl"
jq -nc --arg t "$work/live.jsonl" --argjson r $((now + 5000)) --argjson w $((now + 200000)) '{
  transcript_path: $t, model: {display_name: "Opus"}, effort: {level: "high"},
  context_window: {used_percentage: 55.4, context_window_size: 1000000,
    current_usage: {input_tokens: 10, cache_read_input_tokens: 554000}},
  rate_limits: {five_hour: {used_percentage: 12, resets_at: $r}, seven_day: {used_percentage: 85, resets_at: $w}}}' >"$work/full.json"
raw=$(node "$cli" <"$work/full.json")
line=$(plain <<<"$raw")
[ "$line" = "Opus · high   context 55% (554k/1M)   cache 57m   5h 12% · 1h 23m   week 85% · 2d 7h" ] || fail "full line: $line"
grep -Fq $'\033[31m85%' <<<"$raw" || fail "85% must be red"
grep -Fq $'\033[33m55%' <<<"$raw" || fail "55% must be yellow"
grep -Fq $'\033[32m12%' <<<"$raw" || fail "12% must be green"

# An expired cache is shown as a red "exp.".
printf '{"type":"assistant","timestamp":"%s","message":{"usage":{"cache_creation":{"ephemeral_5m_input_tokens":10}}}}\n' \
  "$(stamp $((now - 4000)))" >"$work/expired.jsonl"
raw=$(jq -c --arg t "$work/expired.jsonl" '.transcript_path = $t' "$work/full.json" | node "$cli")
grep -Fq $'cache \033[31mexp.\033[0m' <<<"$raw" || fail "expired cache not marked: $raw"

# A reply that reported no cache tokens shows no countdown.
printf '{"type":"assistant","timestamp":"%s","message":{"usage":{"input_tokens":5,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"cache_creation":{"ephemeral_5m_input_tokens":0,"ephemeral_1h_input_tokens":0}}}}\n' \
  "$(stamp $((now - 60)))" >"$work/nocache.jsonl"
raw=$(jq -c --arg t "$work/nocache.jsonl" '.transcript_path = $t' "$work/full.json" | node "$cli" | plain)
grep -Fq 'cache' <<<"$raw" && fail "no-cache transcript must show no countdown: $raw"

# prompt_cache from the status JSON wins over the transcript; a null expires_at hides the cache.
raw=$(jq -c --argjson e $((now + 600)) '.prompt_cache = {expires_at: $e}' "$work/full.json" | node "$cli" | plain)
grep -Fq 'cache 9m' <<<"$raw" || grep -Fq 'cache 10m' <<<"$raw" || fail "prompt_cache.expires_at not used: $raw"
raw=$(jq -c '.prompt_cache = {expires_at: null}' "$work/full.json" | node "$cli" | plain)
grep -Fq 'cache' <<<"$raw" && fail "null prompt_cache.expires_at must show no countdown: $raw"

# Missing fields, a missing transcript, and invalid input never crash or print noise.
[ -z "$(printf '{}' | node "$cli" | plain | tr -d '\n')" ] || fail "empty input must print an empty line"
[ "$(printf '{"model":{"display_name":"Sonnet"},"transcript_path":"%s/none"}' "$work" | node "$cli" | plain)" = "Sonnet" ] || fail "missing transcript"
[ -z "$(printf 'not json' | node "$cli")" ] || fail "invalid input must print nothing"

# A reader never writes: the run leaves the work directory unchanged.
before=$(find "$work" -type f | sort | xargs sha256sum)
node "$cli" <"$work/full.json" >/dev/null
[ "$before" = "$(find "$work" -type f | sort | xargs sha256sum)" ] || fail "the status line wrote a file"
echo "statusline probe passed"
