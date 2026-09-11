# b-design

Create or refresh `docs/DESIGN.md`, the repo-local frontend design standard. Do not implement UI code.

## When to use

- The user asks to create, rewrite, extract, or normalize frontend design guidance.
- The requested output is `docs/DESIGN.md` or a shared frontend style standard.
- The user provides screenshots, mockups, existing UI files, or prose describing a desired product style.

## When NOT to use

- The user wants frontend code changed now -> use **b-frontend** after design guidance exists or is unnecessary.
- The user wants live visual/browser evidence -> use **b-browser**.
- The user wants a broader implementation plan -> use **b-plan**.
- The repo already has sufficient design-system docs and the task is only to follow them -> use the relevant build or validation skill.

## Tool guidance

- `bash` - `rtk git status --short`, diffs, and modern discovery (`rg`, `fdfind`, `eza`).
- `read`/`edit`/`write` - inspect sources and update only `docs/DESIGN.md` unless broader docs were approved.

## Steps

1. Confirm the source mode: user description, attached image/mockup, existing `docs/DESIGN.md`, design-token source, current frontend code, or a mix.
2. Run `rtk git status --short` via Bash for repo work and preserve unrelated changes.
3. Inspect the lightest useful evidence: existing design docs, frontend components, tokens, CSS, layout files, screenshots, and repo conventions. Use native `read` first. Do not invent a design system when evidence is thin. Before drafting, make an explicit, task-conditional design read: identify the surface, audience, brand/repository evidence, hierarchy, density, layout variance, and motion posture; then state one product-appropriate art direction and its anti-default constraints. Treat marketing pages, product apps, dashboards, and trust/regulated surfaces differently. If evidence leaves materially different directions, ask one focused question rather than guessing.
4. If analyzing images, separate observed facts from inferred rules. Treat exact dimensions, counts, colors, and spatial alignment as approximate unless supported by source files or browser evidence.
5. Create or update only `docs/DESIGN.md` with edit/write unless the user explicitly approved a broader documentation change. Preserve useful existing content and remove generic filler. If an unresolved product choice is material and user-facing, use `ask_user_question` [cap: package.pi-ask-user-question] with 2–4 concrete options, the recommended option first, and the automatic custom-answer row; if unavailable or noninteractive, ask one focused plain-text question. Otherwise, record the unresolved choice as an open question.
6. Keep the document implementation-facing and concise. Prefer rules an agent can apply while coding over design theory.
7. Include exact tokens only when supported by repo evidence. Include a short verification checklist that later **b-frontend** and **b-browser** work can use, plus a task-conditional self-audit for typography, palette, composition/layout repetition, surface/card restraint, meaningful interactions, truthful copy/assets, responsive behavior, and accessibility.
8. Verify referenced paths exist where possible, then inspect the diff for unsupported claims and ceremony.

## Structure guidance

Do not force a long default skeleton when evidence is sparse. Cover only the durable standards the evidence supports.

Use the following as an adaptable checklist, not a required document outline:

- Product character, audience, and workflows
- Visual principles and layout system
- Color, typography, spacing, density, and radius
- Components and interaction states
- Responsive behavior and accessibility
- Implementation rules, do's/don'ts, and verification checklist
- Source evidence and open questions

Omit YAML front matter when exact token values are not evidenced or when the repo already has a better token source.

## Content rules

- State durable standards for the product, not page-specific implementation notes.
- Make the chosen art direction and anti-default constraints explicit without turning them into a one-style-fits-all prescription.
- Make rules concrete: density, radius, spacing scale, component usage, icon usage, color roles, typography scale, empty/loading/error states, and responsive behavior.
- Keep prose primary. Tokens capture exact values; prose explains visual intent, tradeoffs, scarcity rules, and negative constraints.
- Prefer current repo tokens, components, and CSS variables over newly invented values.
- Keep image-derived guidance honest: use language like "appears", "inferred", or "approximate" when the evidence is visual-only.
- Do not require every frontend task to run this skill. `docs/DESIGN.md` is a reusable artifact, not a mandatory phase.
- Do not add marketing-page guidance unless the product actually needs marketing pages.
- Do not replace visual QA. Route screenshot or browser proof to **b-browser**.

## Output format

Files changed, evidence used, verification, confidence level, and open questions.

## Rules

- Do not implement UI code.
- Do not claim pixel-perfect extraction from images.
- Do not add generic design advice that would fit any app.
- Reject recognizable generic AI defaults such as unmotivated gradients, repeated centered heroes, three equal feature cards, or indiscriminate glass surfaces unless the brief or evidence explicitly calls for them; do not replace them with another fixed aesthetic.
- Do not prescribe a particular font, icon library, dark mode, image-generation workflow, or heavy motion without evidence from the brief or repository.
- Do not create extra root docs or design artifacts without explicit scope.
- Do not scaffold unused section headings when repo evidence is sparse.
