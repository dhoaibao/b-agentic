Mode: changed-code

Baseline:
- Approved plan and changed diff were available for review.

Coverage / Tests / Operability:
- `bash scripts/validate-skills.sh`
- `bash scripts/validate-skills.sh --release`
- smoke-install.sh passed

Checked and clean:
- Status schema matches policy.

```text
[status]
skill: b-review
run-id: 20260531-163343-policy-model
state: complete
artifacts: none
next: b-ship
blockers: none
verdict: READY FOR PR
```
