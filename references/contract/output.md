## Output Contract

Default output is concise prose. Use structured blocks only when they reduce ambiguity: handoffs, blockers, review verdicts, or shipping.

### Handoff

Use before another skill must continue the work.

```text
[handoff]
source: <b-skill-name>
goal: <one-line goal>
decisions: <confirmed decisions or 'none'>
assumptions: <open assumptions or 'none'>
files: <relevant paths or 'none'>
verification: <expected check or 'none'>
blockers: <known blockers or 'none'>
next-skill: <b-skill-name>
```

### Blocked Work

Use when the requested work cannot continue.

```text
[blocked]
skill: <b-skill-name>
reason: <one-line blocker>
needs: <user action, tool, evidence, approval, or external fix>
done: <what was completed or 'none'>
```

### Review Verdicts

| Verdict | Meaning |
|---|---|
| `READY FOR PR` | No blocking findings; baseline and required verification are covered. |
| `READY WITH FOLLOW-UPS` | Mergeable only if named gaps are accepted. |
| `NEEDS FIXES` | BLOCKER or MAJOR findings should be fixed before merge. |

Findings come first in reviews, ordered by severity with file references when available.

### Ship Checklist

Before commit, push, or PR creation, report branch, intended staged files, recent commit context, verification, and the exact command that needs approval.

---
