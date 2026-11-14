# shellcheck shell=bash
# shellcheck disable=SC2154,SC2034 # Variables are shared with state-probe.sh and the other files it sources.
# Helpers of the state probe: run the CLI, write artifacts, make a repository. Sourced by state-probe.sh.
fail() { echo "state probe failed: $*" >&2; exit 1; }

make_repo() {
  local dir=$1
  mkdir -p "$dir"
  git -C "$dir" init -q .
  git -C "$dir" config user.email probe@example.invalid
  git -C "$dir" config user.name probe
  printf 'a\n' >"$dir/a.txt"
  git -C "$dir" add .
  git -C "$dir" commit -qm init
}

# st REPO OWNER ARGS...: run the CLI in REPO as OWNER; prints stdout, sets $rc.
st() {
  local repo=$1 owner=$2
  shift 2
  rc=0; [ -z "${STATE_PROBE_DEBUG:-}" ] || echo "st: $*" >&2
  out=$(cd "$repo" && node "$cli" "$@" --owner "$owner" 2>"$work/err") || rc=$?
}
ok() { st "$@"; [ "$rc" -eq 0 ] || fail "expected success ($*): rc=$rc $(cat "$work/err")"; }
refused() { st "$@"; [ "$rc" -eq 3 ] || fail "expected refusal ($*): rc=$rc $(cat "$work/err")"; }
invalid() { st "$@"; [ "$rc" -eq 2 ] || fail "expected invalid input ($*): rc=$rc $(cat "$work/err")"; }
phase() { jq -r .phase "$1"/.b-agentic/runs/*/state.json; }
sfile() { printf '%s' "$1"/.b-agentic/runs/*/state.json; }

# Artifact helpers: specs, plans and QA files come from claude/bin/b_run.py only.
run_cli="$root/claude/bin/b_run.py"
br() { # REPO OWNER ARGS... (JSON on stdin)
  local repo=$1 owner=$2
  shift 2
  (cd "$repo" && python3 -I -B "$run_cli" "$@" --owner "$owner")
}
# CONSENT_COMMIT, CONSENT_TARGET and CONSENT_CODEX set the spec's consent block; every
# approve call below repeats the same values.
spec_json() { # N [SCOPE]: N automated criteria that run "make test"
  jq -n --argjson n "$1" --arg scope "${2:-**}" --arg commit "${CONSENT_COMMIT:-yes}" \
    --arg target "${CONSENT_TARGET:-current}" --arg codex "${CONSENT_CODEX:-reviewer}" '{request: "probe request", answers: [],
    behavior: {current: [], new: ["x"], examples: [{input: "a", output: "b"}, {input: "c", output: "d"}], non_goals: []},
    criteria: [range(1; $n + 1) | {id: "AC-\(.)", when: "a", then: "b", evidence: "automated", command: "make test"}],
    scope_paths: [$scope], out_of_scope: [],
    consent: {commit: $commit, branch_target: $target, codex: $codex}}'
}
plan_json() { jq -n '{steps: [{id: "S-1", action: "do", paths: ["a.txt"], done_when: "done"}], checks: ["make test"], invariants: [], stop_conditions: []}'; }
write_artifacts() { # REPO N [SCOPE]
  spec_json "$2" "${3:-**}" | br "$1" s1 write spec >/dev/null || fail "write spec ($1)"
  plan_json | br "$1" s1 write plan >/dev/null || fail "write plan ($1)"
}
# apply_steps REPO: record the one step of plan_json; verify is refused until every step is recorded.
apply_steps() { ok "$1" s1 record step S-1; }
write_qa() { # REPO N VERDICT RESULT
  jq -n --argjson n "$2" --arg verdict "$3" --arg result "$4" '{rows: [range(1; $n + 1) | {ac: "AC-\(.)", evidence: "automated", command: "make test", result: $result}],
    regression_scope: "all", not_covered: [], verdict: $verdict}' | br "$1" s1 write qa >/dev/null || fail "write qa ($1)"
}

repo="$work/repo"
make_repo "$repo"

