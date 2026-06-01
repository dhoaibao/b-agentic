Verification:
- `bash scripts/validate-skills.sh`

```text
[handoff]
source: b-review
run-id: 20260531-170300-review-fix-loop
goal: Fix the blocking review finding and rerun review.
decisions: Keep the change scoped to the finding.
assumptions: none
files: tooling/conformance/checker.py
verification: bash scripts/validate-skills.sh
blockers: none
next-skill: b-implement
```

