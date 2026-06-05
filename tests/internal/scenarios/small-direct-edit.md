Task start:
- Active skill: `b-implement`
- Source of truth: small direct edit request
- Success: requested edit applied and narrow validation passes
- Worktree: `git status --short` showed no unrelated conflicts

Verification:
- `bash scripts/validate-skills.sh`

```text
[status]
skill: b-implement
run-id: 20260531-170000-small-direct-edit
state: complete
artifacts: none
next: b-review
blockers: none
```
