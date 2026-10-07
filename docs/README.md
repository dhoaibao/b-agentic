<!-- b-init-managed:start -->

# Docs

This index tells agents where project docs go. Each folder's README holds its
naming, template, and rules. The design baseline is
[ADR-001](decisions/ADR-001-b-agentic-design-record.md).

## Folders

| Folder                           | Holds                                                              |
| -------------------------------- | ------------------------------------------------------------------ |
| [references/](references/)       | Material sourced from external research.                           |
| [runbooks/](runbooks/)           | Guides to set up or operate the project.                           |
| [decisions/](decisions/)         | ADRs: why a choice was made.                                       |
| [architecture/](architecture/)   | As-built structure and diagrams from `b-drawio` or `b-excalidraw`. |
| [specs/](specs/)                 | Requirements and approved plans.                                   |

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
- Use lowercase kebab-case ASCII `.md` names with no dates. `README.md` and
  `DESIGN.md` are the exceptions.

<!-- b-init-managed:end -->
