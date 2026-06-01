# Browser-Boundary Card

Use this before deciding whether browser-related work stays in `b-test`, moves to `b-browser`, or blocks PR readiness.

- Simulated DOM, component tests, unit tests, integration tests, and contract tests stay in `b-test`.
- Real browser, page navigation, screenshots, visual diff, browser session/state, live UI, and e2e checks belong to `b-browser`.
- Missing real-browser evidence is not covered by non-browser tests.
- `READY FOR PR` is not allowed when relevant browser evidence is still missing unless the user explicitly accepts a follow-up and the outcome is downgraded.

Modes:
- `lite` is fine for local non-browser tests.
- `strict` is required when browser evidence affects readiness or needs live-browser approval.

The authoritative boundary table and readiness rules live in `../contract/10-decisions.md` and `../contract/09-output.md`.
