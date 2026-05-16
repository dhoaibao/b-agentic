# b-test — reference

Fallback testing patterns for `b-test` when a repo's own test conventions are thin or inconsistent.

## Test shape

- Prefer behavior assertions over implementation-detail assertions.
- Name the scenario and the expected outcome, not the helper being called.
- Add the smallest regression test that would fail if the behavior reverts.

## Coverage priorities

- Changed behavior first.
- Public contract surfaces next.
- High-fan-in helpers after that.
- Opportunistic branch coverage last.

## Fixtures and mocks

- Keep fixtures local unless a shared fixture already matches the scenario.
- Mock the boundary you do not own; keep the code under test realistic.
- Avoid broad global mocks when a narrow stub or builder is enough.

## Assertions

- Cover happy path, edge case, and error path when they matter to the change.
- Assert user-visible or contract-visible behavior.
- Prefer one strong expectation over many weak incidental ones.

## Snapshot discipline

- Update a snapshot only after the intended behavior is explicitly confirmed.
- Treat large snapshot rewrites as suspicious until the behavior change is understood.
