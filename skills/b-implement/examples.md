# b-implement — Examples

## Example 1: Execute next plan step

**User input:** `/b-implement .b-agentic/b-plan/add-rate-limiting.md`

**Plan state:** 3 of 5 steps complete. Step 4: "Add express-rate-limit middleware to API routes."

**Step flow:**

1. Load source of truth: read `.b-agentic/b-plan/add-rate-limiting.md`, confirm `status: approved`, check `blocked_by: none`
2. Check worktree: `git status --short` shows clean tree
3. Pre-edit checkpoint: "Step 4 of 5: add rate-limit middleware to src/app.js, behavior that must not change: existing routes still work, verification: npm test"
4. Edit: insert `app.use(rateLimit({ windowMs: 15 * 60 * 1000, max: 100 }))` in src/app.js
5. Verify: `npm test` passes, 42 tests green
6. Record progress: update plan checkboxes, `status` remains `in-progress`

**Output:**
```text
Plan source: .b-agentic/b-plan/add-rate-limiting.md
Step progress: 4 of 5 complete
Changes: src/app.js — added express-rate-limit middleware
Verification: npm test passes (42/42)
Blockers/Decisions: none
Next: Step 5 — add rate-limit configuration to config/default.json
```

## Example 2: Small direct request

**User input:** `/b-implement "Add a helper function capitalize(str) to src/utils/string.js"`

**Step flow:**

1. Load source of truth: small direct request (1 file, no export change, obvious behavior)
2. Check worktree: one untracked file unrelated to src/utils
3. Pre-edit checkpoint: "Small direct: add capitalize() to src/utils/string.js, behavior: capitalizes first letter only, verification: run existing string utils tests"
4. Edit: add `export const capitalize = (str) => str.charAt(0).toUpperCase() + str.slice(1);`
5. Verify: `npm test -- string` passes, 8 tests green including new behavior

**Output:**
```text
Plan source: small direct request
Step progress: complete
Changes: src/utils/string.js — added capitalize helper
Verification: npm test -- string passes (8/8)
Blockers/Decisions: none
Next: none
```
