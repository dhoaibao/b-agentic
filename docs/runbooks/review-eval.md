# Review eval

Score how well a `b-review` round finds known blockers without flagging clean
changes. The fixture is [`tests/behavior/review-eval.json`](../../tests/behavior/review-eval.json);
`tooling/validate/review_eval.py` checks it offline as part of
`scripts/validate-skills.sh`. Nothing here runs a model on its own.

## Prerequisites

- A full clone with history: the case commits must exist (`git rev-parse --is-shallow-repository` prints `false`).
- A clean working tree, so the review sees only the case.
- Approval for each live run. A reviewer run sends repository code to Codex or
  a subagent, so ask the user before every run (kernel rule 5); never run it in
  CI or unattended.

## Fixture

Each case has a `base` and a `head` commit and a `split`.

- `incident`: a change that holds a blocker. `answer_key` is the one sentence a
  round should find, `blocker_class` is one of the b-review blocker classes,
  and `fixed_by` lists the commits that later fixed it. The expected verdict is
  `NEEDS FIXES`.
- `control`: a merged change that no later fix commit is known to correct. The expected
  verdict is `no blocker`. It is a heuristic for clean: a blocker a round finds
  here may be real, so read it before counting it as an over-flag.
- `introducing-commit`: `head` is the commit that introduced the defect and
  `base` is its parent. `revert-of-fix`: `base` is a fix and `head` is its
  parent, so the diff reintroduces the defect and is a smaller, easier read than
  the original change. `merged-change` is the control form.
- `split`: `tuning` cases may be used to change the review prompt; `test`
  cases are frozen. `test_set_digest` pins the test split, so editing one means
  updating the digest in the same change, which makes the edit deliberate.

## Steps

1. Pick a case and review the exact change between its commits as the
   `b-review` handoff would see it: the diff from `base` to `head` with no
   knowledge of `fixed_by` or `answer_key`. Do not paste either into the
   handoff or the focus text.
2. Run one fresh review round for the case (the Codex gate, or `b-reviewer`
   when Codex is unavailable), and note its verdict and each blocker.
3. Score the case:
   - **Blocker caught** (incident): a round names a blocker that matches the
     `answer_key` at the right location. Count a different blocker as extra, not
     as a catch.
   - **Over-flag** (control): a round returns `NEEDS FIXES` for a control.

   Report both rates per split: caught per incident and over-flagged per
   control.

4. Change the review prompt only after reading the `tuning` results, then
   re-score. Report the `test` split only to confirm a change, and do not read
   its answer keys while editing the prompt. A change that raises the tuning
   catch rate and raises the test over-flag rate has overfit.
5. Keep results outside the repository (they carry model output about private
   code). Record only the prompt change and the two rates in the commit or PR
   description.
6. Add a case from a new incident or revert: take the introducing commit when
   it is a bounded change, otherwise the fix as `revert-of-fix`; write a
   one-sentence key; choose the split; and, for a test case, update
   `test_set_digest` (the validator prints the expected form on a mismatch).

## Verify

Run `python3 tooling/validate/review_eval.py`. It prints `review-eval passed`
with the case count and `history checks ran`; in a shallow clone it prints
`history checks skipped: shallow clone` instead, and only the shape, split, and
digest checks apply.
The leak and blocker-class checks are tripwires (a verbatim copy, a substring
of the prompt), not proof that the prompt is free of the answers.

## Troubleshooting

- `test_set_digest does not match`: a test case changed. Recompute the digest
  (`sha256` of the test-split cases as canonical JSON, keys sorted, no spaces)
  and put it in the fixture.
- `commits not in history`: the clone is missing those commits; fetch them
  before scoring.
- `a test answer key leaked into b-review`: an answer key now appears verbatim in the
  review prompt or the kernel. Reword the prompt; do not weaken the key.
