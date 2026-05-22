# b-refactor — Examples

## Example 1: Rename an internal helper

**User input:** `/b-refactor "Rename formatDate to formatIsoDate in src/utils/dates.js"`

**Step flow:**

1. Lock target: `formatDate` in `src/utils/dates.js`
2. Map impact: Serena `find_referencing_symbols` shows 4 call sites in `src/components/`, none exported
3. Risk: trivial — one file change, internal refs only, no public contract
4. Transform: symbol rename via Serena
5. Verify: diagnostics pass, `grep -r "formatDate" src/` shows only the new name

**Output:**
```text
Target: formatDate -> formatIsoDate in src/utils/dates.js
Risk: trivial
Impact: 4 internal call sites in src/components/*
Changes: renamed symbol, updated 4 imports
Verification: diagnostics clean, grep confirms no stale references
Follow-up: none
```

## Example 2: Extract duplicate validation logic

**User input:** `/b-refactor "Extract the email validation duplicated in register.js and reset-password.js"`

**Step flow:**

1. Lock target: email regex + length check appearing in both files
2. Map impact: exact text search finds 2 occurrences, no other matches
3. Risk: low — 2 files, internal logic, behavior-preserving
4. Behavior boundary: same regex, same length limits, same error message
5. Transform:
   - Create `src/utils/validateEmail.js` with extracted function
   - Replace both occurrences with `validateEmail(email)`
   - Add import to both files
6. Verify: run `npm test -- auth`, existing tests still pass

**Output:**
```text
Target: Duplicate email validation in register.js and reset-password.js
Risk: low
Impact: 2 files, internal logic, no exported change
Changes: new src/utils/validateEmail.js, replaced 2 occurrences
Verification: npm test -- auth passes
Follow-up: none
```
