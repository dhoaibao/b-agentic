# b-debug — Examples

## Example 1: Null pointer from stack trace

**User input:** `/b-debug "Getting TypeError: Cannot read property 'name' of undefined at getUserProfile (src/auth.js:42)"`

**Step flow:**

1. Frame symptom: exact error, expected vs actual, repro command `npm test -- auth.test.js`
2. Rank suspects: stack points to `src/auth.js:42`, function `getUserProfile`
3. Read `src/auth.js` line 42: `return user.name` where `user` comes from `findUserById(id)`
4. Check `findUserById`: returns `null` when user not found, no null check at call site
5. Root cause: `getUserProfile` dereferences `user` without checking `findUserById` returns null
6. Fix: add `if (!user) return null;` before line 42
7. Verify: run `npm test -- auth.test.js`, previously failing test now passes
8. Cleanup: no probes added

**Output:**
```text
Symptoms: TypeError when calling getUserProfile with non-existent user ID
Root cause: getUserProfile dereferences findUserById result without null check
Fix: Added null guard at src/auth.js:41
Verification: npm test -- auth.test.js passes
Cleanup: none
```

## Example 2: Slow API endpoint

**User input:** `/b-debug "User list endpoint takes 8s, used to take 200ms"`

**Step flow:**

1. Frame symptom: 8s actual vs 200ms baseline, repro: `curl -w "@curl-format.txt" http://localhost:3000/api/users`
2. Check regression window: last deploy 2 days ago touched `src/services/userService.js`
3. Read changed file: new `getUsers` fetches all users, then loops to enrich each with `getDepartment` (N+1)
4. Measure: 500 users × 1 query each = 501 queries total
5. Root cause: N+1 query introduced in getUsers during department enrichment
6. Fix: replace loop with `SELECT ... JOIN departments` single query
7. Verify: before 8.2s, after 180ms

**Output:**
```text
Symptoms: /api/users degraded from 200ms to 8s
Root cause: N+1 query in getUsers — 501 queries for 500 users
Fix: Replaced loop with JOIN query in src/services/userService.js
Verification: before 8.2s, after 180ms (curl measured)
Cleanup: none
```
