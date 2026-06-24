---
name: b-design
description: >
  Frontend design-standard authoring for creating or refreshing
  `docs/DESIGN.md` from user descriptions, attached images or mockups,
  existing frontend files, or current design docs. Use when Codex needs to
  extract, normalize, or rewrite shared UI style guidance for future
  frontend implementation. Unlike b-implement, it writes design guidance
  rather than UI code; unlike b-browser, it does not collect final browser
  evidence.
argument-hint: "[design-source-or-goal]"
---

<!-- Generated from skills/registry.yaml and skills/b-design/prompt.md. Edit those sources, not this file. -->

# b-design

$ARGUMENTS

Create or refresh `docs/DESIGN.md`, the repo-local frontend design standard. Do not implement UI code.

## When to use

- The user asks to create, rewrite, extract, or normalize frontend design guidance.
- The requested output is `docs/DESIGN.md` or a shared frontend style standard.
- The user provides screenshots, mockups, existing UI files, or prose describing a desired product style.

## When NOT to use

- The user wants frontend code changed now -> use **b-implement** after design guidance exists or is unnecessary.
- The user wants live visual/browser evidence -> use **b-browser**.
- The user wants a broader implementation plan -> use **b-plan**.
- The repo already has sufficient design-system docs and the task is only to follow them -> use the relevant build or validation skill.

## Tools required

- `bash` - inspect repo files, git state, docs, and diffs.
- `serena` - inspect frontend structure when code ownership or component patterns affect the standard.
- `playwright` - inspect supplied or local visual evidence only when browser evidence is already in scope or approved.

## Steps

1. Confirm the source mode: user description, attached image/mockup, existing `docs/DESIGN.md`, current frontend code, or a mix.
2. Run `git status --short` for repo work and preserve unrelated changes.
3. Inspect the lightest useful evidence: existing design docs, frontend components, tokens, CSS, layout files, screenshots, and repo conventions. Do not invent a design system when code evidence is thin.
4. If analyzing images, separate observed facts from inferred rules. Treat exact dimensions, counts, colors, and spatial alignment as approximate unless supported by source files or browser evidence.
5. Create or update only `docs/DESIGN.md` unless the user explicitly approved a broader documentation change. Preserve useful existing content, remove generic filler, and mark unresolved product choices as open questions.
6. Keep the document implementation-facing and concise. Prefer rules an agent can apply while coding over design theory.
7. Include a verification checklist that later **b-implement** and **b-browser** work can use.
8. Verify referenced paths exist where possible, then inspect the diff for stale generated text, unsupported claims, and ceremony.

## DESIGN.md Structure

Use this structure unless the repo already has a clearer standard:

```markdown
# Frontend Design Standard

## Product Character
## Audience And Workflows
## Visual Principles
## Layout System
## Color System
## Typography
## Spacing And Density
## Components
## Interaction States
## Responsive Behavior
## Accessibility
## Implementation Rules
## Verification Checklist
## Source Evidence
## Open Questions
```

## Content Rules

- State durable standards for the product, not page-specific implementation notes.
- Make rules concrete: density, radius, spacing scale, component usage, icon usage, color roles, typography scale, empty/loading/error states, and responsive behavior.
- Keep image-derived guidance honest: use language like "appears", "inferred", or "approximate" when the evidence is visual-only.
- Prefer current repo tokens, components, and CSS variables over newly invented values.
- Do not require every frontend task to run this skill. `docs/DESIGN.md` is a reusable artifact, not a mandatory phase.
- Do not add marketing-page guidance unless the product actually needs marketing pages.
- Do not replace visual QA. Route screenshot or browser proof to **b-browser**.

## Output format

Files changed, evidence used, verification, confidence level, and open questions.

## Rules

- Do not implement UI code.
- Do not claim pixel-perfect extraction from images.
- Do not add generic design advice that would fit any app.
- Do not create extra root docs or design artifacts without explicit scope.
