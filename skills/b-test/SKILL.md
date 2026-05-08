---
name: b-test
description: >
  Test-driven development, test debugging, and test coverage evaluation. ALWAYS invoke
  when the user asks about writing tests, fixing failing tests, test coverage gaps,
  or TDD: "test", "viết test", "failing test", "test đang fail", "bắt đầu bằng test",
  "test coverage", "missing test".
  Unlike b-debug (traces runtime bugs), b-test focuses on test-specific failures:
  wrong assertions, missing mocks, setup issues, coverage gaps.
effort: medium
---

# b-test

$ARGUMENTS

Dedicated skill for test-driven development, test debugging, and coverage evaluation.
Failing CI test and runtime bug have different patterns — this skill owns the test path.

If `$ARGUMENTS` is provided, treat it as the test task or failing test symptom.
Proceed directly. Do not ask "what test do you want to write?" unless `$ARGUMENTS` is empty.

## When to use

- User asks to write tests for new or existing code.
- A test is failing and the issue is assertion, mock, or setup — not runtime logic.
- Evaluating whether test coverage is adequate for a behavior change.
- User says: "test", "viết test", "test case", "failing test", "test coverage",
  "TDD", "unit test", "integration test", "test đang fail", "bắt đầu bằng test",
  "missing test".

## When NOT to use

- Runtime bug in production code → use **b-debug**
- Need a plan for a feature → use **b-plan**
- Review code before PR → use **b-review**
- Quick library API lookup → use **b-research**
- Browser/UI testing or user-flow verification → use **b-e2e**

## Tools required

- `Bash` — run test commands, inspect test output, locate test files.
- `Read`, `Edit`, `Write` — native file tools for inspecting tests and creating new test files when no suitable file exists.
- `check_onboarding_performed`, `onboarding`, `find_symbol`, `get_symbols_overview`, `find_referencing_symbols`, `replace_symbol_body`, `insert_before_symbol`, `insert_after_symbol` — from `serena` MCP server *(required for discovering test files and mapping tests to source symbols)*
- `resolve-library-id`, `query-docs` — from `context7` MCP server *(optional, for verifying testing framework API — jest, vitest, pytest, etc.)*
- `sequentialthinking` — from `sequential-thinking` MCP server *(optional, for choosing test strategy: unit vs integration vs e2e)*

If Serena is unavailable: use Bash to find test files (`find`, `ls`) and `Read` for inspection. Note: "⚠️ Serena unavailable — test discovery via file listing."
If sequential-thinking is unavailable: choose test strategy inline with explicit pros/cons list.

Graceful degradation: ✅ Possible — core test debugging works with Bash + Read + Edit/Write.

## Steps

### Step 1 — Discover test structure

Find test files and understand the test setup:

1. Use Bash to locate test files and identify the testing framework:
   ```bash
   # Common patterns
   find . -name "*.test.*" -o -name "*.spec.*" | head -20
   cat package.json | grep -A2 '"test"'
   ```
   (Adapt for Python, Go, Java, Rust — `find` test files with language conventions.)

2. Call `check_onboarding_performed`. If false, call `onboarding`.

3. Call `get_symbols_overview` on relevant test files to see test structure
   (describe blocks, test functions, setup/teardown, shared fixtures).

4. Call `find_symbol` on the test name or describe block if the user mentioned a specific test.

5. If the user mentions "missing test" or "write tests for X": call `find_symbol`
   on the source code symbol that needs tests, then `find_referencing_symbols`
   to see if it already has tests.

**Goal**: know the framework, the test file structure, and the relationship between tests and source code.

---

### Step 2 — Identify task type

Pick the branch that matches the work:

- **Branch A — Failing test**: a test is red and the user wants it green.
- **Branch B — Write tests**: TDD or filling a coverage gap with new tests.
- **Branch C — Evaluate coverage**: report on what is and isn't covered, then recommend (and optionally write) the highest-value missing tests.

Use `sequentialthinking` for branch selection only if the user's request is genuinely ambiguous (e.g. "make my tests better"). Otherwise pick from `$ARGUMENTS` directly.

---

### Step 3 — Branch A: Fix failing test

1. Read the failing test output via Bash:
   ```bash
   npm test 2>&1 | tail -50
   # or
   pytest -x 2>&1 | tail -30
   ```
2. Read the failing test code with `Read` (narrow section, not full file).
3. Read the source code under test (the function/class being tested).
4. Identify the gap between expected and actual:

| Symptom | Fix |
|---|---|
| Wrong expected value | Update assertion to match correct output |
| Missing mock | Add mock/stub for the dependency |
| Leaking state | Reset state in `beforeEach` or `afterEach` |
| Async timing | Add `await`, return promise, or use `waitFor` |
| Wrong test data | Provide realistic input matching the scenario |
| Real bug in production code | Fix production code via symbol-aware edits, then re-run |

Apply the minimal fix. Prefer `replace_symbol_body` for whole test functions over line-level `Edit`.

---

### Step 4 — Branch B: Write tests

1. Identify what behavior needs testing:
   - From a plan file → read the acceptance criteria.
   - From `$ARGUMENTS` → parse the behavior description.
   - From source code → read the source symbol, list its branches and edge cases.
2. Use `sequentialthinking` to choose strategy *only if ambiguous*:
   - Pure function → unit test
   - DB interaction → integration test
   - User workflow → e2e (delegate to /b-e2e) or integration test
3. Cover:
   - **Happy path** (normal input → expected output)
   - **Edge cases** (empty input, boundary values, null/undefined)
   - **Error path** (invalid input → error thrown/rejected)
   - **Regression prevention** (would catch a revert of the current change)
4. Insert tests using Serena where possible:
   - `insert_after_symbol` / `insert_before_symbol` — add tests within an existing describe block.
   - `Write` — only when no suitable test file exists in the conventional location.

**Framework-specific conventions**:
- Jest/Vitest: `describe/it`, `beforeEach`, `mock()`
- Pytest: `def test_*`, fixtures, `monkeypatch`
- Go: `Test*` with `t.Run`, `assert.Equal`
- Rust: `#[test]`, `assert_eq!`

---

### Step 5 — Branch C: Evaluate coverage

1. Run the project's coverage command via Bash:
   ```bash
   npm test -- --coverage
   pytest --cov=.
   go test -cover ./...
   cargo tarpaulin    # if installed
   ```
2. Identify uncovered branches/lines, prioritized by:
   - Symbols implementing explicit requirements
   - Symbols at service boundaries
   - Symbols with the broadest references (`find_referencing_symbols`)
3. Report the gap: file → uncovered branch → why it matters.
4. Optionally write the top 1–3 missing tests using the Branch B flow. Ask the user before committing to a long batch.

---

### Step 6 — Run and verify

1. Run the specific test(s) via Bash:
   ```bash
   npm test -- --testNamePattern="test name"
   pytest path/to/test.py::test_function
   go test -run TestFunction ./pkg
   cargo test test_function
   ```
2. Confirm the test passes.
3. For new tests: run the full suite to confirm no regressions.
4. If tests fail: go back to the relevant branch. Maximum 3 iterations.

---

## Output format

```
### b-test: [test task]

**Type**: [write tests / fix failing test / evaluate coverage]
**Framework**: [jest / vitest / pytest / go test / cargo test]
**Test scope**: [unit / integration / e2e]

#### Test structure
- [test file path] — [describe blocks or test functions found]

#### Issue / Requirements
[what was wrong or what behavior needs testing]

#### Fix / Implementation
[code change — exact assertion, mock, or test added]

#### Verification
\`\`\`bash
[test command and result]
\`\`\`
✅ Test passes / ❌ Test still failing — [next step]

---

#### Coverage *(only when Branch C)*
- Before: [X%] lines
- After: [Y%] lines
- Gaps: [what is still not covered, ranked by priority]
```

---

## Rules

- Never modify production code to make a test pass unless the production code is actually buggy.
- A failing test often reveals a bug in production code → if analysis confirms a real bug, fix production code via symbol-aware edits, then re-run the test.
- Keep test fixes minimal — if one assertion is wrong, fix that assertion; do not rewrite the entire test suite.
- Write behavior tests (assert on output), not implementation tests (assert on internal state).
- Use `sequentialthinking` for test strategy decisions only if the choice is genuinely ambiguous.
- Never trigger destructive git commands.
- If the test output is truncated in the terminal: increase verbosity or pipe to a file then `Read` the file.
- Prefer running specific tests over the full suite during debugging — faster feedback loop.
