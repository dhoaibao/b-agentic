# b-init Templates

Use this file as a drafting aid after you have inspected the repository. Do not copy it blindly.

## Managed Block Markers

Newly generated files should include these markers around the managed body. When refreshing an existing file, prefer:

```md
<!-- b-init-managed:start -->
...
<!-- b-init-managed:end -->
```

If a file already exists without these markers and contains substantial content, preserve it and ask before replacing large sections.

## Managed Body Pattern

Use this shape for first-run output:

```md
<!-- b-init-managed:start -->
...generated content...
<!-- b-init-managed:end -->
```

Human-owned notes may live above or below the managed block.

## `AGENTS.md` Outline

Keep the file short. Include only sections supported by repo evidence.

1. Repository purpose
2. Working rules for agents
3. Verification commands
4. Codebase map
5. Safety or do-not-assume notes
6. Maintainer guide
7. Source-of-truth files

### Section Guidance

- `Repository purpose`: one short paragraph on what the repo ships or maintains.
- `Working rules for agents`: local conventions, edit boundaries, generated-vs-source guidance, and approval expectations that matter in this repo.
- `Verification commands`: only list commands that exist in the repo.
- `Codebase map`: top-level directories or packages that matter for navigation.
- `Safety or do-not-assume notes`: constraints such as generated files, migrations, shared environments, secrets, or runtime-specific boundaries.
- `Maintainer guide`: include only when contributors need repo-specific editing guidance.
- `Source-of-truth files`: explicitly name registries, templates, or docs that own generated outputs.

## `CLAUDE.md` Pattern

Keep it intentionally thin:

```md
# Claude Code Instructions

Read `./AGENTS.md` first. It is the source of truth for this repository's agent instructions and maintainer guidance.
```

If the repository uses a subdirectory target, point to the nearest relevant `AGENTS.md`.

## Content Guardrails

- Do not add runtime-home install paths unless the repo itself owns those paths.
- Do not restate generic model behavior or safety policy unless the repo requires a concrete variant.
- Do not invent workflows, owners, commands, or release steps.
- Prefer a missing-detail TODO over a polished hallucination.
