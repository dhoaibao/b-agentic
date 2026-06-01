# Routing Card

Use this before switching skills or deciding whether to stay in the current one.

- Keep exactly one active skill.
- Use `b-orchestrate` only for explicit end-to-end PR-readiness workflows.
- Use `b-plan` when scope, acceptance criteria, or sequencing are unclear, or when the work is non-trivial and not yet approved.
- Use `b-implement` for approved plans and small direct requests with no remaining design decision.
- Use `b-refactor` for concrete behavior-preserving transforms.
- Use `b-debug` when runtime behavior is uncertain or a failing test may expose a real product bug.
- Use `b-test` for unit, integration, contract, simulated-DOM, and component-test work.
- Use `b-browser` for real-browser, visual, screenshot, browser-session, live UI, and e2e evidence.
- Use `b-review` for changed-code review or an explicit suite audit.
- Use `b-ship` only on explicit commit/push/PR intent after review readiness exists.

Modes:
- `lite` for trivial local work with no design decision.
- `standard` by default.
- `strict` whenever public, sensitive, dependency, CI/release, multi-phase, or shared-environment risk applies.

The authoritative routing and switch rules live in `../contract/01-routing.md` and `../contract/10-decisions.md`.
