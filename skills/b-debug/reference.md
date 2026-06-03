# b-debug reference

Use for systematic root-cause analysis and minimal fixes.

## Symptom framing checklist

- [ ] Exact error message or stack trace captured
- [ ] Expected vs actual behavior stated
- [ ] Reproduction steps are deterministic (or nondeterminism is noted)
- [ ] Environment differences checked (recent commits, dependency changes, config drift)
- [ ] For perf bugs: metric, workload, baseline, and threshold are named

## Root-cause confirmation rules

1. **Cheapest proof first**: exact error search, local diagnostics, narrow repro
2. **Temporary probes only when necessary**: tag every probe with `b-debug-probe`
3. **State the root cause explicitly**: "Root cause: `<what fails>` because `<why>`"
4. **Cannot reproduce**: capture environment differences and ask for exact repro/logs

## Fix verification checklist

- [ ] Narrowest check that proves the symptom changed
- [ ] For nondeterminism: stress repro with sufficient iterations
- [ ] For perf: before/after measurements reported
- [ ] All `b-debug-probe` markers removed
- [ ] Verification re-run after cleanup

## Common pitfalls

- **Do not bundle cleanup or redesign** with the minimal fix
- **Do not patch speculatively** unless user explicitly asks for defensive change
- **Do not skip root-cause confirmation** before applying the final fix
- **Measure before claiming perf improvement** — intuition is not evidence

## When to hand off

- Confirmed cause needs structural work → hand off to **b-plan** with root cause and evidence
- Fix spans multiple modules and needs sequencing → hand off to **b-plan**
- Fix is behavior-preserving mechanical work → hand off to **b-refactor**
