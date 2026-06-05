Active skill: `b-implement`
Source of truth: approved saved plan
Success: validator rejects mismatched intent/action
Worktree: `git status --short` clean

```text
[intent]
skill: b-implement
action: dependency-write
commands: npm install left-pad
source: user request
approval: pending
reason: intentionally mismatched dependency write
```

```text
[status]
skill: b-implement
state: blocked
artifacts: none
next: none
blockers: intent/action mismatch
cause: policy_block
```
