Mode: changed-code

Findings:
- BLOCKER: `tooling/conformance/checker.py` accepts readiness claims while blocking findings are still present.

Coverage / Tests / Operability:
- `bash scripts/internal-check-conformance.sh --self-test tests/internal/conformance/cases.json`

Checked and clean:
- Status schema matches policy.

```text
[status]
skill: b-review
run-id: 20260604-204500-ready-blocking-finding
state: complete
artifacts: none
next: b-ship
blockers: none
verdict: READY FOR PR
```
