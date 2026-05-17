# b-skills — Repo conventions & skill authoring

Guidelines for creating, editing, and maintaining the install-only OpenCode skill suite in this repository.

## Scope

- This file is maintainer guidance for the source repository.
- Runtime suite behavior lives in `global/AGENTS.md` (kernel), `references/runtime-contract.md` (detailed contract), and `skills/*/SKILL.md` (per-skill).
- `install.sh` deploys runtime files to `~/.config/opencode/`, always writes `AGENTS.b-skills.md`, and replaces `AGENTS.md` only when missing or approved.
- When authoring runtime-facing skill prose, reference `AGENTS.md`. Long-form schemas, rubrics, and edge-case protocols live in `references/runtime-contract.md`.

## Quick links

- `skills/b-spec/SKILL.md` — Clarify underspecified requests before planning
- `skills/b-plan/SKILL.md` — Task decomposition and planning
- `skills/b-research/SKILL.md` — Library docs and multi-source research
- `skills/b-implement/SKILL.md` — Approved-plan execution
- `skills/b-refactor/SKILL.md` — Behavior-preserving code transforms
- `skills/b-debug/SKILL.md` — Hypothesis-driven debugging
- `skills/b-test/SKILL.md` — Test writing, coverage, and test-only failures
- `skills/b-e2e/SKILL.md` — Real-browser flow verification and test authoring
- `skills/b-review/SKILL.md` — Pre-PR changed-code review
- `skills/b-audit/SKILL.md` — Repository and suite-slice audits
- `references/` — Reusable checklists and the detailed runtime contract
- `global/AGENTS.md` — Runtime kernel source (installs as `AGENTS.b-skills.md`)
- `commands/` — Thin slash-command wrappers

---

## Frontmatter spec

Every `skills/<name>/SKILL.md` must begin with YAML frontmatter:

```yaml
---
name: b-skill-name
description: >
  [Trigger-focused description, <=80 words. Answer only: "when should OpenCode load this skill?"
  Include: ALWAYS trigger condition and one sentence distinguishing this from
  similar skills.
  Do NOT include usage instructions — those go in the skill body.]
compatibility: opencode
metadata:
  suite: b-skills
---
```

**Required fields:**
- `name` — kebab-case, prefixed with `b-`
- `description` — <=80 words, trigger-focused only

**OpenCode-supported optional fields:**
- `license`
- `compatibility`
- `metadata`

**Repo conventions:**
- Set `compatibility: opencode`
- Set `metadata.suite: b-skills`

**Do not carry forward Claude-only frontmatter fields** such as top-level `effort`, `model`, `disable-model-invocation`, `user-invocable`, or `paths`.

**Description rules:**
- Start with a one-line summary of what the skill does
- Include `ALWAYS invoke when...` with a short, intent-shaped condition
- End with one-clause disambiguation from the most similar skill
- Keep Vietnamese trigger words in `global/AGENTS.md` or `references/runtime-contract.md` routing aids rather than spamming every skill description with multilingual keyword lists
- No step-by-step instructions, no tool lists, no output format details

---

## Skill directory structure template

```text
skills/<name>/
├── SKILL.md           # Main instructions (required)
├── reference.md       # Detailed reference (optional)
├── examples.md        # Usage examples (optional)
└── scripts/           # Utility scripts (optional)
    └── helper.sh

commands/<name>.md     # Matching slash-command wrapper (required in this repo)
```

For this repo, each skill uses a single `SKILL.md` file plus a thin command wrapper. Add extra files (`reference.md`, `examples.md`, `scripts/`) only when they materially improve maintenance — for example, externalize long templates to `reference.md` so `SKILL.md` stays scannable under context pressure (see `skills/b-plan/reference.md`).

## Shared references

Top-level `references/*.md` files are allowed when two or more skills need the same checklist or pattern guidance.

- Keep them short, task-oriented, and reusable across skills.
- They may define optional conventions, such as glossary/domain-doc layouts, when adding a whole new skill would be overkill.
- If a skill points at a shared reference, ensure `install.sh` syncs it into `~/.config/opencode/references/b-skills/`.
- Treat reference-file changes like runtime-facing guidance: keep `README.md` and `REFERENCE.md` aligned in the same commit.

---

## Skill file structure template

```markdown
---
name: b-example
description: >
  [<=80 words, intent + disambiguation. Do NOT include trigger keyword
  lists; those live in AGENTS.md and maintainer docs.]
compatibility: opencode
metadata:
  suite: b-skills
---

# b-example

$ARGUMENTS

[1-2 sentence summary of what this skill does and why it exists.]

## When to use
- [Bullet list of scenarios]

## When NOT to use *(optional but recommended)*
- [Scenarios that should trigger a different skill instead]

## Tools required
- `bundle-name` (see `AGENTS.md` §4)
- `bundle-name` *(optional, for [condition])*

Skills reference **MCP bundles** by name (e.g., `serena-symbol-toolkit`,
`gitnexus-radar`, `context7-docs`). Do not enumerate per-tool lists inside
the skill; the bundle definition in `AGENTS.md` is the source of
truth, including session-init steps, fallback ladder, and cost/approval
caveats.

Fallbacks: reference `AGENTS.md` MCP fallback ladder. Skills add
only skill-specific stop/degrade behavior.

Graceful degradation: [✅ Possible / ⚠️ Partial / ❌ Not possible] — [brief explanation]

## Steps

### Step 1 — [Name]
[Imperative instructions. Every step must have action verbs.]

### Step 2 — [Name]
...

---

## Output format
[Template or example of expected output]

---

## Rules
- [Bullet list of constraints and guardrails. Do NOT restate severity,
  risk, iteration cap, privacy gate, onboarding rule, confidence signal,
  run-id format, artifact paths, slug algorithm, status block, handoff
  envelope, manifest schema, test-vs-bug decision, DOM/browser boundary,
  or canonical approval ask — those live in AGENTS.md and skills
  reference them.]
```

---

## Command wrapper template

Every skill in this repo must have a matching `commands/<name>.md` wrapper:

```markdown
---
description: Run the b-example skill for [short purpose]
---

Load the `b-example` skill and follow it exactly for this request.

$ARGUMENTS
```

Keep command wrappers thin. They are entrypoints, not duplicate logic stores.

---

## MCP selection criteria

Skills declare MCP usage by referencing **bundles** summarized in `global/AGENTS.md` §4 and fully defined in `references/runtime-contract.md` §4 — not by enumerating individual tool names. Bundle definitions own session-init steps, fallback behavior, cost/approval caveats, and language-coverage caveats.

| Role | When to add | Example |
|---|---|---|
| **Primary** | Skill cannot function without it | `playwright-browser` for `b-e2e` |
| **Secondary** | Skill uses it conditionally for a specific step | `context7-docs` in `b-debug` for API-misuse checks |
| **Optional** | Enhances quality but skill works without it | `gitnexus-radar` in any code-touching skill |

**Rules:**
- Never add a bundle just to increase coverage — every bundle must have a clear use case in the Steps section.
- Reference the bundle name. Do not paste the per-tool list into the skill; that list belongs in `references/runtime-contract.md` §4.
- Label each bundle in "Tools required" with its role: required vs `*(optional, for [condition])`*.
- Always include a `Graceful degradation:` line summarizing skill-specific fallback (the generic MCP fallback ladder lives in `references/runtime-contract.md` §4 and is not restated).
- Write skill prose to prefer the lightest capable tool. Do not force MCP-first behavior for exact strings, manifests, prose, small file reads, or other cases where native tools are cheaper and equally reliable.
- Do not list `sequential-thinking` in a skill's tool table. The global rules describe when to reach for it inline; it is not a per-skill dependency.
- Do not list `*_unsafe` tool variants (e.g., browser code-execution) in skill workflows. Approval is required per-invocation; they are excluded from default toolkits.

**GitNexus-specific criteria:**
- GitNexus is always **optional radar** for this suite. It is never a primary dependency of any skill and never acts as the editing layer.
- Serena is **primary hands** for exact symbol discovery, source inspection, references, and symbol-aware edits.
- Add `gitnexus-radar` to a skill only when graph-level intelligence (cross-file impact, architecture context, execution-flow discovery, stale-index detection, route/API consumers, multi-repo mapping) materially improves the workflow. GitNexus is the preferred first step for graph-shaped tasks only when the repo is **indexed, fresh, and target-aware**; Serena then handles exact symbol inspection and edits.
- If the target symbol or file is already known, or the task is local to a single file/module, skip GitNexus and go straight to Serena.
- Every skill that uses GitNexus must rely on the freshness gate summarized in `global/AGENTS.md` §4 and fully defined in `references/runtime-contract.md` §4, then fall back to Serena/native tools when the gate fails.
- When both MCPs appear in one workflow, GitNexus answers the graph question first; Serena then becomes the source of truth for symbol lookup, body inspection, references, and edits. Do not keep both active on the same exact question.
- Before maintainers suggest `gitnexus analyze --skip-agents-md` or add indexing guidance to a skill, verify it is **only when indexing is safe**.

---

## File sync rules

All skills live in `skills/<name>/SKILL.md`. When changing skill files:

| Change type | Action |
|---|---|
| **Create** new skill | Create `skills/<name>/SKILL.md` and `commands/<name>.md` |
| **Update** skill | Edit `skills/<name>/SKILL.md` and keep `commands/<name>.md` aligned. If the change adds or modifies a long template/skeleton, externalize it to `skills/<name>/reference.md` and link from `SKILL.md` |
| **Delete** skill | Delete `skills/<name>/SKILL.md`, `commands/<name>.md`, any `reference.md`/`examples.md`/`scripts/`, and the directory if empty |

**Runtime contract sync** — when always-on runtime behavior changes, update `global/AGENTS.md`; when detailed schemas/rubrics/protocols change, update `references/runtime-contract.md`. Keep related repo docs aligned in the same commit.

**Root `AGENTS.md`** — keep repo-level maintainer guidance in the root `AGENTS.md` so it remains available when working in this source repository.

---

## Doc sync rule

**Any change to a skill file — create, update, or delete — requires updating both `README.md` and `REFERENCE.md` in the same commit.**

| Change type | README.md | REFERENCE.md |
|---|---|---|
| **Create** skill | Add row to skills overview table | Add full reference section |
| **Update** skill | Update the skill overview and install/source-layout notes if changed | Rewrite the skill's reference section to match |
| **Delete** skill | Remove the skill from the overview and source-layout docs | Remove the skill's reference section entirely |

Never leave README or REFERENCE out of sync with a skill file change.

---

## Quality checklist

Before merging any skill file change, verify:

1. **Description <=80 words** — verify with `wc -w` on the extracted description text
2. **Every step has imperative verbs** — "Call X", "Extract Y", "Check Z" — not "X is called" or "Y should be extracted"
3. **Fallbacks are explicit without duplication** — global MCP fallbacks cover shared behavior; skills state only local stop/degrade differences
4. **Inter-skill handoffs have trigger conditions** — "if [condition] -> use /b-[other]" with the specific condition, not just "consider using"
5. **No trigger keyword regression** — before rewriting a description, list all current trigger keywords and verify all survive in the new version
6. **Suite validator passes** — run `scripts/validate-skills.sh` before installing or committing skill changes
7. **No avoidable churn** — steps should not force repeated Serena preflights, optional MCP escalation, or skill switches when the current skill can complete with bounded evidence
8. **No duplicated global concepts** — slug algorithm, status block, handoff envelope, manifest schema, approval ask, fallback labeling, tool-use heuristics, empty-state defaults, plan staleness gates, workspace isolation preference, review checkpoint cadence, completion closure protocol, and the DOM-unit vs browser boundary all live in `global/AGENTS.md` or `references/runtime-contract.md`. Skills reference them; they do not restate them.
