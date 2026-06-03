# b-implement reference

Use for executing approved plans and small direct requests.

## Plan validation checklist (before starting)

- [ ] Frontmatter is valid (slug, status, risk, touch_points)
- [ ] Approval is explicit (saved plan approved_at, or current-chat approval)
- [ ] Touch points match current repo state (no stale paths)
- [ ] Every unchecked step has `Done when` verification
- [ ] No blocked dependencies

## Small-direct-request threshold

A request may bypass `b-plan` when ALL of the following are true:
- Touches 3 or fewer files
- No public contract change
- No sensitive path (auth, security, billing)
- No design decision required

If any condition fails, hand off to **b-plan**.

## Adjacent discovery classification

During implementation, classify unexpected findings:

- **Required**: Must fix now; blocks current step
- **Blocking decision**: Needs user input or plan revision; stop and ask
- **Follow-up**: Out of scope; note in status block and continue

## Verification patterns

- **Saved plan**: run the plan's `Done when` check
- **No plan**: run touched-file diagnostics + narrowest relevant command
- **TypeScript/JavaScript**: `npm run typecheck` or `tsc --noEmit`
- **Python**: `python -m py_compile` or `pytest` on changed modules
- **Generic**: build/test command from manifest or CI config

## Common pitfalls

- **Do not add opportunistic refactors** — file a follow-up instead
- **Do not implement without approval** — stop with `cause: user_blocked`
- **Do not skip verification** — even for "obvious" one-liners
- **Preserve unrelated worktree changes** — run `git status --short` before editing

## When to stop

- New decisions required → stop, recommend **b-plan**
- Broader verification needed → stop, recommend **b-test** or **b-browser**
- Review checkpoint reached → stop, recommend **b-review**
- Next step is higher risk → stop, ask for approval
