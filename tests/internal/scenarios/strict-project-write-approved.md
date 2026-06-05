Active skill: `b-implement`
Source of truth: approved saved plan `.b-agentic/b-plan/state-machine-governance.md`
Success: project-write intent matches the planned contract edit
Worktree: `git status --short` clean

```text
[intent]
skill: b-implement
action: project-write
files: references/contract/state-machine.md
source: .b-agentic/b-plan/state-machine-governance.md
approval: not-required
reason: add state-machine contract from approved plan
```

strict: enforced
pre-action project-write validated

Verification: `python3 -m py_compile tooling/state/validator.py` passed.

```text
[status]
skill: b-implement
state: complete
artifacts: none
next: b-review
blockers: none
```
