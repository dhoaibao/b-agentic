Active skill: `b-implement`
Source of truth: approved saved plan
Success: edit the approved docs
Worktree: `git status --short` clean

```text
[intent]
skill: b-implement
action: project-write
files: references/contract/runtime.md
source: .b-agentic/b-plan/state-machine-governance.md
approval: not-required
reason: implement approved governance contract update
```

Verification: `python3 -m py_compile tooling/conformance/checker.py` passed.

```text
[status]
skill: b-implement
state: complete
artifacts: none
next: none
blockers: none
```
