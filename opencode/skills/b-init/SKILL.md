---
name: b-init
description: >
  Initialize or refresh repo-local agent instruction docs: canonical
  AGENTS.md plus a minimal CLAUDE.md shim that routes readers to
  AGENTS.md. Grounds the docs in repo evidence, preserves user-owned
  content, and keeps the output slim. Also establishes a docs/ structure:
  a docs/README.md index plus a README in each docs folder that define
  where agent-authored docs go, how they are named, and minimal templates.
  Routing signals: /init, init agent docs, initialize agent docs, create
  AGENTS.md, create CLAUDE.md, refresh AGENTS.md, refresh agent docs.
metadata:
  phase: Build
  execution_mode: main
---

<!-- Generated from skills/registry.yaml and skills/b-init/prompt.md. Edit those sources, not this file. -->

# b-init

Initialize or refresh repo-local agent instruction docs. `AGENTS.md` is canonical. `CLAUDE.md` is a thin redirect shim. `docs/README.md` and the README in each docs folder tell agents where project docs go.

## When to use

- The user wants a project-level `/init` equivalent for agent guidance.
- `AGENTS.md` or `CLAUDE.md` is missing, stale, or inconsistent.
- A repo needs a concise maintainer guide grounded in its actual structure.
- A repo lacks a `docs/README.md` index for agent-authored docs, or it is stale.

## When NOT to use

- The task is runtime-home installation or adapter config -> use repo docs or installer flow.
- The user wants a broader plan before writing docs -> use **b-plan**.
- The user wants frontend/UI code or behavior changes -> use **b-frontend**; other code or product behavior changes -> use **b-implement**.

## Tool guidance

- `bash` - inspect the repository layout, status, and existence of referenced paths or commands.
- `read`/`edit`/`write` - inspect source guidance and make precise documentation changes while preserving user-owned text.

## Steps

1. Confirm the target scope (repository root or a subtree) and whether this is a create, refresh, or reconcile operation.
2. Run `rtk git status --short` before inspecting or changing the repository. Preserve unrelated changes.
3. Before drafting, inventory only the evidence needed for a useful guide:
   - language and package manifests, lockfiles, and the repository's actual lint, format, type, test, and CI configuration or scripts;
   - local canonical docs and any documented architecture or design decisions;
   - existing `docs/` files and folders, including `docs/README.md` and `docs/DESIGN.md`; and
   - observable technical surfaces that could make a change unsafe or easy to misplace, such as request/input, authentication, persistence or migrations, rendering/templates/HTML, external integrations, and infrastructure/deployment.
   Treat absent evidence as absence. Do not infer a stack, risk surface, command, owner, policy, or enforcement claim that the repository does not show.
4. Establish the ownership boundary before writing:
   - `AGENTS.md` is the canonical instruction file. Keep `CLAUDE.md` as the exact thin redirect shim when it is in scope.
   - Only the text between `<!-- b-init-managed:start -->` and `<!-- b-init-managed:end -->` is b-init-managed. `## Project Rules` is developer-owned, must stay outside those markers, and must be preserved verbatim; it must never be regenerated, moved, or deleted during refresh.
   - If a target has meaningful unmarked content, unmarked-content replacement remains a material choice. Do not silently replace it; ask whether to preserve it, explicitly replace it, or stop.
   - A legacy four-section managed block is not proof that every line was generated. Do not silently discard unknown content. Surface it and request a material migration choice before replacing the block.
   - `docs/README.md` and each docs folder README follow the same marker rule: only the text between its `<!-- b-init-managed:start -->` and `<!-- b-init-managed:end -->` markers is b-init-managed, and text outside them is developer-owned. An existing README without markers is user-owned; reconcile it with the same preserve, explicit-replace, or stop choice. An existing docs folder only needs its README added or refreshed.
   - Never move, rename, or delete existing docs to match the convention. Report non-conforming docs as a focused gap, or offer to move them as a separate explicit choice.
5. Resolve material choices before editing. Use the installed questionnaire for grouped options; if it is unavailable, ask one focused plain-text question directly to the user. Offer a preserve option, a clean-baseline migration option only when the user explicitly approves it, and a stop option. A clean-baseline choice may remove old generated boilerplate, but any specifically identified durable developer rule must be moved to `## Project Rules` verbatim rather than lost. Without an explicit choice, leave the existing content unchanged.
6. Build the managed block as a slim, strong, usable operating guide. It must contain exactly these ordered top-level sections and no other level-two section:
   - `## Repository Purpose` - one short paragraph stating what the repository ships or maintains, grounded in repository evidence.
   - `## Project Operating Guide` - use descriptive nested headings only as evidence warrants. Cover only (a) architecture and change map: where relevant changes belong; (b) canonical sources, generated outputs, and required change flows: what owns truth and which companion or regeneration steps are required; (c) project-specific constraints and boundaries that could cause an incorrect change; and (d) one short nested heading (for example `### Documentation`) that points to `docs/README.md` for creating and updating docs; do not copy its folder roles, naming, or templates into `AGENTS.md`. (Folder-level naming and templates live in each folder README.)
   - `## Verification` - list each existing, applicable repository verification command once. Keep this to normal checks for the project, not an exhaustive setup, release, diagnostic, or tool-readiness catalog. If an applicable check is absent, state a focused gap or TODO instead of inventing a command.
7. Create or refresh `docs/README.md` and one `README.md` in each of `docs/references/`, `docs/runbooks/`, `docs/decisions/`, `docs/architecture/`, and `docs/specs/`, creating the five folders even when they hold no other doc. The folder README is what tracks an empty folder; add no `.gitkeep` or other placeholder. Put the generated content of each file between its managed markers, and keep each README short without repeating facts across files.
   - `docs/README.md` states: (a) folder roles: `references/` for material sourced from external research; `runbooks/` for guides to set up or operate the project; `decisions/` for ADRs; `architecture/` for as-built structure and diagrams from **b-drawio** or **b-excalidraw**; `specs/` for requirements and approved plans; (b) a "where does doc X go" rule that maps a doc's purpose to one folder; (c) shared naming: lowercase kebab-case ASCII `.md`, no dates in filenames, except `README.md` and `DESIGN.md`, and `docs/DESIGN.md` stays at the docs root under **b-design**; (d) the shared rule: search for an existing doc and update it in place before creating one.
   - Each folder README states its one-line role, its naming, a minimal template as one heading list, and its own rules:
     - `references/`: `<subject>.md`; Source/Retrieved/Version, Summary, Key facts, Implications for this repo; every doc carries a `Source` URL and a `Retrieved` date.
     - `runbooks/`: `<verb>-<object>.md`; Purpose, Prerequisites, numbered Steps, Verify, Troubleshooting; commands must be runnable and end with a Verify step.
     - `decisions/`: `ADR-NNN-<kebab-title>.md` (3 digits, never reused); Status/Date/Supersedes, Context, Decision, Consequences; refinements update an ADR in place and a reversed decision gets a new ADR with `Supersedes: ADR-NNN`; `README.md` is not an ADR.
     - `architecture/`: `<area>.md`, and a diagram shares its basename (`.drawio` or `.excalidraw`); Scope, Components, Flow/diagram, Ownership and boundaries, Related ADRs; describe the current state and leave the reasons to ADRs.
     - `specs/`: `<feature>.md`, unnumbered; Status (draft, approved, implemented), Goal, Requirements, Acceptance criteria, Out of scope; update `Status` as the spec progresses.
8. Include only facts that answer where to change, source of truth, required companion or regeneration changes, a non-obvious project constraint, or how to verify. Prefer links to deeper docs over copied catalogs. Omit non-actionable catalogs or link to deeper docs instead of copying them into `AGENTS.md`. Ground non-obvious claims in paths or links to evidence, and distinguish configuration-backed conventions from contextual boundaries or gaps.
9. Apply the output quality standard: slim means no duplicated facts or exhaustive catalog; strong means explicit ownership, evidence, boundaries, and verification; usable means an agent can find the next edit and required flow quickly. Preserve the project's "slim, strong, usable" philosophy as a concrete b-init output quality standard.
10. Keep generic kernel workflow, tool, and secret policy out of the project supplement. The always-loaded kernel owns that guidance; do not restate, weaken, or replace it. If evidence is insufficient, write a bounded gap rather than a generic best-practice or security catalog.
11. Verify that referenced paths and commands exist. Use `bash` for repository-local checks, regenerate any generated skill output from its canonical source, confirm the docs READMEs exist with resolving links and that no `.gitkeep` or other placeholder files were added, and inspect the diff for noise, discarded developer rules, duplicated verification, or invented detail.

## Output format

Files changed (including the docs READMEs), repository evidence used, verification, and any focused gaps left intentionally unresolved.

## Rules

- Keep `AGENTS.md` primary and `CLAUDE.md` minimal.
- Create only the docs READMEs and their five folders, with no `.gitkeep` or placeholder files; never move existing docs without an explicit choice.
- Preserve developer-owned `## Project Rules` verbatim outside the managed markers.
- Edit canonical sources and regenerate generated skill output; do not hand-edit `SKILL.md`.
- Prefer evidence-backed orientation and links over metadata dumps or command catalogs.
- Use explicit migration choices and focused gaps instead of guessing or silently discarding content.
- Keep the result slim, strong, and usable.
