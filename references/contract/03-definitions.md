## 3. Definitions and rubrics

The single glossary all skills defer to. Do not redefine these terms inside individual skill files.

### Non-trivial work

A change is **non-trivial** if any is true:
- Touches more than 3 files.
- Touches a public contract (exported API, route, CLI flag, schema, migration).
- Touches a sensitive path (auth, authz, billing, secrets, crypto, persistence migrations).
- Adds, removes, or changes a dependency.
- Modifies CI, build, or release configuration.
- Requires sequencing.

Otherwise the change is **trivial** and may use the lightweight paths in each skill.

### Small direct request

A request that may bypass `b-plan` and go straight to `b-implement` must meet **all** of:
- 3 or fewer files.
- No exported/public contract change.
- No sensitive path (auth, security, billing, migration).
- No remaining design decision; behavior is obvious from the request.

Anything failing this threshold goes back to `b-plan`.

### Behavior modes

Use these mode labels consistently across the kernel, cards, docs, and prompts:

- **lite** — trivial local work, no public/sensitive/dependency/CI/release/sequenced risk, and no remaining design decision. Keep ceremony low, but still honor source-of-truth and worktree checks.
- **standard** — default operating mode for ordinary code and docs work. Use the decision cards for point-of-use reminders and escalate to the detailed contract when a card does not settle the question.
- **strict** — required for any public contract, sensitive path, dependency change, CI/build/release change, multi-phase or orchestrated work, or shared-environment or external mutation. Make approval, staleness, worktree, verification, and output gates explicit at the point of use.

Override rules:
- user may request stricter mode
- lite is not allowed when any strict trigger applies

### Readiness vocabulary

Use these terms consistently across skills:
- **Verified** means the stated check or runtime observation ran and directly supports the claim.
- **Validated** means the artifact or plan passed required structural checks, but behavior may still need verification.
- **Complete** means the requested scope is done, required verification ran or was explicitly skipped, and no blockers remain.
- **Partial** means useful progress or artifacts exist, but completion criteria are not satisfied.
- **Ready** means no known blockers remain within the reviewed or implemented scope; it does not imply unreviewed surfaces are safe.

Do not use `READY FOR PR`, `complete`, or high confidence when the required baseline, verification, or evidence is missing. For UI/browser-relevant work, real-browser/visual/e2e checks are covered only by `b-browser`-verified supplied/CI evidence, existing-tool evidence, approved live-browser evidence, or an accepted follow-up; otherwise use `READY WITH FOLLOW-UPS`, `partial`, or a lower confidence label.

### Severity rubric (`b-review`, `b-debug`, any finding)

| Severity | Meaning |
|---|---|
| **BLOCKER** | Correctness, security, data-loss, or contract violation. Cannot ship. |
| **MAJOR** | Likely regression, missing coverage on changed behavior, or operability gap in a new entry point. Should fix before PR. |
| **MINOR** | Bug-prone code, edge case, or follow-up cleanup that does not block the PR. |
| **NIT** | Style, naming, or preference. Authors may ignore. |

### Risk rubric (`b-refactor`, `b-implement`, verification depth)

| Risk | Criteria |
|---|---|
| **trivial** | One file, no exported change, few or no external references, behavior preserved. |
| **low** | Single module, internal refs only, narrow tests cover the area. |
| **medium** | Multi-file, exported/shared symbol, or partial test coverage. |
| **high** | Public contract, schema, migration, auth/security/billing path, or known broad blast radius. |

Match verification depth to the risk band per the verification ladder (§7).

### Confidence signal

When an answer rests on incomplete evidence, end with one line:

`Confidence: high | medium | low — <one-clause reason>.`

- **high** = direct evidence (runtime, primary docs, symbol bodies). Omit the line entirely.
- **medium** = consistent secondary evidence.
- **low** = single weak source, snippet only, or material gap.

Skip the line on trivial high-confidence answers (a single docs lookup with a direct hit) to avoid ceremony. Always include it on partial, single-source, or recency-sensitive answers.

---
