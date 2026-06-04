# b-test reference

Operational guide for test work: framework detection, failure classification, snapshot handling, and handoffs.

## Framework detection patterns

Look for these signals in order:
1. **Package manifest** — `package.json` scripts, `pytest.ini`, `jest.config.*`, `vitest.config.*`, `karma.conf.*`
2. **CI workflow** — test commands in `.github/workflows/`, `.gitlab-ci.yml`, etc.
3. **File conventions** — `*.test.*`, `*.spec.*`, `__tests__/`, `tests/`, `test_*.py`
4. **Lockfile evidence** — `jest`, `vitest`, `pytest`, `mocha`, `ava` in `package-lock.json`/`poetry.lock`

If no framework exists, hand off to **b-plan** before adding one.

## Snapshot and golden procedures

- **Never update without confirming intended behavior** — read the source change, test intent, and user request first.
- **Run the narrowest target** — `npm test -- -u path/to/test` or `pytest --snapshot-update path/to/test`.
- **Review diff before committing** — snapshot changes should match the behavioral change.
- **Flag unexpected snapshot churn** — large diffs without clear source changes indicate a harness or dependency drift.

## Mock and fixture debugging

- **Mock drift**: check if the mocked module signature changed; update the mock to match.
- **Fixture scope**: verify `setup`/`teardown` ordering; check for state leakage between tests.
- **Async timing**: look for missing `await`, resolved promises, or timer mocks.
- **Module resolution**: verify mock paths match the actual import paths (case-sensitive, extension-aware).

## Common assertion failure classifications

| Symptom | Likely cause | Lane |
|---|---|---|
| `expected X, received Y` with clear behavior change | Product code changed | **b-debug** if intent is unclear; **b-test** if intent is confirmed |
| `Cannot find module` / `ImportError` | Mock path or dependency drift | **b-test** |
| Snapshot mismatch after unrelated change | Harness or dependency drift | **b-test** |
| Timeout / hanging test | Async leak, infinite loop, or resource contention | **b-debug** |
| `TypeError: Cannot read property` | Mock incomplete or module API change | **b-test** |
| Coverage drop without code change | Test deletion or branch shift | **b-test** |

## When to hand off

- **Product behavior unclear** → **b-debug** with test name, failure output, and source area.
- **Needs new framework or strategy** → **b-plan**.
- **Real-browser evidence needed** → **b-browser**.
- **Pre-PR review** → **b-review**.
