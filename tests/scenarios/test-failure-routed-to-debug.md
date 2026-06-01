Verification:
- `bash scripts/validate-skills.sh`

```text
[handoff]
source: b-test
run-id: 20260531-170600-test-failure-routed-to-debug
goal: Confirm whether the failing test exposes a real product bug.
decisions: Production behavior is uncertain.
assumptions: none
files: tests/unit/example.test.ts
verification: npm test -- example
blockers: none
next-skill: b-debug
```

