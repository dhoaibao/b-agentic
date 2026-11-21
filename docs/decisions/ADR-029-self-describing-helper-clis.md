# ADR-029: Self-describing helper CLIs

- Status: Accepted
- Date: 2026-11-21
- Supersedes: none; refines [ADR-010](ADR-010-run-artifact-cli.md) (the run artifact CLI's usage contract) and [ADR-028](ADR-028-short-helper-wrappers.md) (the wrappers the model types)

## Context

[ADR-028](ADR-028-short-helper-wrappers.md) made the helper commands short, but the model still hit failed calls
whose message did not say what to do:

- `b-run --help`, `b-run help` and `b-state --help` were usage errors (exit 2), and a wrong or incomplete command
  (`b-run lint` without a kind) said only `unknown command`, never the valid ones.
- `b-state` resolved the repository, the run, the mutex and the lock before it judged the command name, so a typo came
  back as a run or lock refusal (exit 3) instead of a usage error.
- Both CLIs refused outside a git worktree with `not inside a git worktree`, without the folder or the fix. A draft
  could pass `lint` from another folder and then fail `write`.
- The text rules `lint` enforces (no leading or trailing whitespace, no control characters, no `<` followed by a
  letter, no backtick in command fields) were visible only after a failure, and the HTML error did not say what matched
  or what to write instead. Placeholders such as `<file>` in skill text were copied into specs and rejected.

## Decision

- `b-run` and `b-state` print their usage on `help`, `--help` and `-h` and exit 0, before any option parsing, schema
  load, stdin read, repository, run, mutex or lock work. The usage names the wrapper under
  `~/.claude/b-agentic/bin/` and lists every command, `worktree` included.
  A standalone help flag, or `help` as the command, wins over an unknown option or an option missing its value: the
  caller asking for usage beside a mistake gets usage. A help-shaped value that an option takes stays a value, and a
  malformed option without a help request is still exit 2.
- `b-state` judges the command name right after parsing its arguments: an unknown or missing command is exit 2 with the
  command list, in every folder and run state.
- `b-run` says which argument a known command lacks (`lint needs one KIND: ...`, `handoff needs one PHASE: ...`,
  `runs takes no argument`) and lists the commands for an unknown one.
- The refusal outside a git worktree stays exit 3 and adds the current folder and `run it from inside the repository`.
  A vanished current folder is the same refusal in both, with `cwd: unavailable`: `b-state` reads its current folder
  only when it needs the repository, so help and the command-name check still answer there.
- The HTML markup error quotes the two matched characters and says to write a placeholder as `FILE` or `{file}`.
  `b-run schema` and `schema KIND` gain an additive `text_rules` list, kept beside the regexes that enforce it.
- Every command the CLIs print for the model to type names its wrapper: the `b-state` `next` lines, the refusals that
  tell the model to write an artifact, the `b-run handoff clarify` packet line, and the path guard's refusal name
  `~/.claude/b-agentic/bin/b-state` or `~/.claude/b-agentic/bin/b-run`, so a literal copy runs instead of exiting 127.
  Text that names a helper without a command to type (the stored `run artifacts changed outside b_run.py` block
  reason, the mutex messages) is unchanged.
- b-flow's verify step tells the model to run each approved plan check verbatim as its own command and to add no pipe
  such as `| tail`, so the exit code it records is that command's own: a pipe reports the last command, and
  `${PIPESTATUS[0]}` is empty in zsh. A pipe the plan's command already contains stays.

Exit codes keep their meaning in each CLI. Three cases move: `--help` goes from 2 to 0 (also beside a malformed option),
a `b-state` unknown or missing command goes from 3 (outside git or when the run or lock refused) to 2, and a
`b-state` command that needs the repository, run from a vanished folder, goes from 2 (the system error) to 3.

## Consequences

- A failed call says what to type next; the rules a draft must follow are visible before `lint` fails.
- Rendered artifact bytes, recorded hashes, gates, locks and consent are unchanged; JSON stdout only gains
  `text_rules`.
- The short names `b-state.mjs` and `b_run.py` remain only where b-flow's own mapping sentence covers them: its prompt
  text and the registry `contract.evidence` strings that render into its phase table. The check on skill prompts and the kernel (`tooling/validate/behavior.py`)
  exempts only `skills/b-flow`.
- Rejected: an `argparse` rewrite (changes every error format), `text_rules` in `references/artifacts.yaml` (the rules
  are enforced in code), per-command help pages (wider than the failure needs), a `--repo` flag or environment override
  (a second source of the repository next to the current folder, with lock and scope risk), renumbering exit codes
  (probes and prompts pin them), escaping or narrowing the HTML rule (a raw tag could hide a criterion from a reader).

Evidence: [`claude/bin/b_run.py`](../../claude/bin/b_run.py),
[`claude/bin/b-state.mjs`](../../claude/bin/b-state.mjs),
[`claude/bin/b-state-git.mjs`](../../claude/bin/b-state-git.mjs),
[`claude/bin/b-state-next.mjs`](../../claude/bin/b-state-next.mjs),
[`claude/hooks/b-path-guard.mjs`](../../claude/hooks/b-path-guard.mjs),
[`skills/b-flow/prompt.md`](../../skills/b-flow/prompt.md),
[`tests/artifacts/artifact-probe.sh`](../../tests/artifacts/artifact-probe.sh), and
[`tests/state/cases/core.sh`](../../tests/state/cases/core.sh).
