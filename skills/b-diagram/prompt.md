# b-diagram

Create a validated, portable technical diagram artifact from explicit user or repository facts. Produce versioned JSON source and a self-contained HTML file with inline SVG; do not infer topology, ownership, runtime behavior, impact, or merge safety.

## When to use

- The user explicitly requests an architecture, system map, workflow, sequence, data-flow, or lifecycle diagram.
- The user needs a reviewable technical communication artifact, not merely an explanation.

## When NOT to use

- Diagram scope, facts, or intended audience are materially unclear -> use **b-plan**.
- The user wants frontend/UI code or visual refresh work -> use **b-frontend**.
- The user wants reusable frontend design guidance -> use **b-design**.
- The user wants real-browser evidence or a visual assessment -> use **b-browser**.
- The user needs external facts -> use **b-research** before authoring the source.

## Tool guidance

- Use `read` and local discovery for the smallest relevant repository evidence. Select CodeGraph [cap: mcp.codegraph] only when a concrete repository-wide architecture, dependency, or call-flow question is central.
- Use the bundled `{{skill_support_path}}/diagram.py` with Python 3. Its `validate` command never writes; its `deliver` command atomically replaces only the named HTML target after validation succeeds.
- Do not fetch URLs or inspect live systems from diagram evidence references.

## Steps

1. Confirm the diagram kind, audience, target path, and source facts. Ask one focused question if any is material and unresolved.
2. Establish the bounded fact set. For repository-based diagrams, distinguish observed source facts from user-provided assumptions; preserve exact paths or symbols only when they are safe to disclose.
3. Create a version-1 JSON source conforming to `{{skill_support_path}}/schema.json`: stable node and edge IDs, labels, explicit edge endpoints, and optional evidence IDs. Cite evidence only as supplied metadata; never claim it was verified unless it was actually read.
4. Run `python3 {{skill_support_path}}/diagram.py validate <source.json>`. Repair only the reported local source defects.
5. Run `python3 {{skill_support_path}}/diagram.py deliver <source.json> <target.html>` only for the user-approved target. This writes one portable HTML/SVG artifact with no external assets.
6. Inspect the source and artifact paths, report the exact validation result, and state what the diagram does not establish. Route browser-based visual proof separately to **b-browser** when requested.

## Content rules

- Use only authored nodes and edges. Do not invent relationships, traffic, deployment placement, owners, risk, or causal impact.
- Keep diagrams sparse: include the primary path and necessary boundaries; put supporting detail in labels rather than multiplying edges.
- Evidence references are citations, not live links to inspect, not authorization to disclose protected content, and not proof of runtime behavior.
- Preserve existing diagram source and artifact conventions when a repository already has them.
- Do not add themes, animation, export formats, external libraries, live viewers, or hosted sharing unless separately approved.

## Output format

Report source path, artifact path, diagram kind, validation result, facts represented, and explicit limits or assumptions.

## Rules

- Do not deliver an invalid source or overwrite a target until validation passes.
- Do not claim the rendered artifact is browser-verified, visually approved, or a complete representation of a system.
- Do not write outside the user-approved target path or introduce dependencies to render a diagram.
