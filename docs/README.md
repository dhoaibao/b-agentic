<!-- b-init-managed:start -->

# Docs

This index tells agents where project docs go. Subfolders are created when their
first doc is written. The design baseline is
[ADR-001](decisions/ADR-001-b-agentic-design-record.md).

## Folders

| Folder          | Holds                                                                                 |
| --------------- | ------------------------------------------------------------------------------------- |
| `references/`   | Material sourced from external research.                                              |
| `runbooks/`     | Guides to set up or operate the project.                                              |
| `decisions/`    | ADRs: why a choice was made.                                                          |
| `architecture/` | As-built structure and diagrams from `b-drawio` or `b-excalidraw`.                    |
| `specs/`        | Requirements and approved plans.                                                      |

`docs/DESIGN.md` stays at the docs root as the frontend design standard owned by
`b-design`.

## Where does a doc go

- Facts gathered from outside the repo: `references/`.
- Steps a person follows to set up, run, or recover the project: `runbooks/`.
- A choice with alternatives and consequences: `decisions/`.
- How the system is built today: `architecture/`.
- What is to be built and how it is accepted: `specs/`.

## Rules

- Search for an existing doc and update it in place before creating one.
- Every `references/` doc carries a `Source` URL and a `Retrieved` date.
- Refinements update an ADR in place. A reversed decision gets a new ADR with
  `Supersedes: ADR-NNN`.

## Naming

Lowercase kebab-case ASCII `.md`, with no dates in filenames. `README.md` and
`DESIGN.md` are the exceptions.

- `decisions/`: `ADR-NNN-<kebab-title>.md`, three digits, never reused.
- `references/`: `<subject>.md`.
- `runbooks/`: `<verb>-<object>.md`.
- `architecture/`: `<area>.md`; a diagram shares its basename (`.drawio` or
  `.excalidraw`).
- `specs/`: `<feature>.md`, unnumbered.

## Templates

- ADR: Status/Date/Supersedes, Context, Decision, Consequences.
- Reference: Source/Retrieved/Version, Summary, Key facts, Implications for this
  repo.
- Runbook: Purpose, Prerequisites, numbered Steps, Verify, Troubleshooting.
- Architecture: Scope, Components, Flow/diagram, Ownership and boundaries,
  Related ADRs.
- Spec: Status (draft, approved, implemented), Goal, Requirements, Acceptance
  criteria, Out of scope.

<!-- b-init-managed:end -->
