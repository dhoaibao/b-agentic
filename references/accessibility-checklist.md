# Accessibility checklist

Use this for focused UI verification when `b-e2e` or another skill needs a compact WCAG-oriented pass on the changed surface.

## Interaction basics

- Every interactive control is reachable by keyboard.
- Focus order matches the visible flow.
- Focus is not trapped unless the component is a real modal or similar contained surface.

## Labels and semantics

- Buttons, inputs, and icon-only controls have an accessible name.
- Roles match the control's behavior.
- Headings and landmarks reflect the page structure.

## State and feedback

- Error messages are associated with the relevant control.
- Loading, disabled, and selected states are announced or otherwise perceivable.
- Status changes are not communicated by color alone.

## Dialogs and overlays

- Opening a dialog moves focus inside it.
- Closing a dialog returns focus to a sensible place.
- Background interaction is blocked when required by the pattern.

## Responsive checks

- The changed surface still works at one mobile and one desktop viewport.
- Controls remain reachable without hidden overflow traps.
