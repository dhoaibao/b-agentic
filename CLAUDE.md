# b-skills — Claude repo conventions & skill authoring

Guidelines for creating, editing, and maintaining the install-only b-skills suite in this repository. The active installer target is a Claude Code-native standalone runtime.

## Scope

- This file is maintainer guidance for the source repository.
- Top-level doc targets: keep `README.md` as the brief repo overview and navigation entrypoint, `CLAUDE.md` as maintainer guidelines for this source repo, and `REFERENCE.md` as the reference guide for each skill in this repo.
- Current runtime suite behavior lives in `global/CLAUDE.md` (concise runtime memory installed as `~/.claude/CLAUDE.md`), `references/runtime-contract.md` (detailed contract), `skills/*/SKILL.md` (per-skill workflow), plus `agents/`, `hooks/`, and `settings/` for Claude-native governance.
- Approved phase 1 runtime target: Claude Code standalone user-level configuration under `~/.claude/`.
- Approved phase 1 distribution target: standalone installer first; optional Claude plugin packaging after standalone parity is verified.
- Public UX target: preserve the 9 short `/b-*` skill names unless a Claude-native constraint forces a rename.
- `install.sh` deploys runtime files to `~/.claude/`, merges `~/.claude/settings.json`, and optionally configures MCP in `~/.claude.json` with backup and dry-run discipline.
- When authoring runtime-facing skill prose, reference installed `CLAUDE.md`, task-specific workflow in skills, enforceable policy in hooks/settings, isolated lanes in agents, and long-form details in references.

## Quick links

- `skills/b-spec/SKILL.md` — Clarify underspecified requests before planning
- `skills/b-plan/SKILL.md` — Task decomposition and planning
- `skills/b-research/SKILL.md` — Library docs and multi-source research
- `skills/b-implement/SKILL.md` — Approved-plan execution
- `skills/b-refactor/SKILL.md` — Behavior-preserving code transforms
- `skills/b-debug/SKILL.md` — Hypothesis-driven debugging
- `skills/b-test/SKILL.md` — Test writing, coverage, and test-only failures
- `skills/b-review/SKILL.md` — Pre-PR changed-code review
- `skills/b-audit/SKILL.md` — Repository and suite-slice audits
- `CLAUDE.md` — Claude maintainer guidance for this source repository
- `global/CLAUDE.md` — concise Claude always-on memory source installed as `~/.claude/CLAUDE.md`
- `references/` — reusable checklists and the current detailed runtime contract
- `agents/` — Claude custom agent definitions
- `hooks/` — Claude hook configs and helper scripts, including `hooks/b-skills-guard.py`
- `settings/` — managed Claude settings/MCP/permission snippets, including `settings/b-skills.settings.json`

---

## Frontmatter spec

Skill files and the installer use Claude-native runtime surfaces. Do not change one skill's activation model without updating all affected docs and validation in the same step.

Every `skills/<name>/SKILL.md` must begin with YAML frontmatter:

```yaml
---
name: b-skill-name
description: >
  [Trigger-focused description, <=80 words. Answer only: "when should Claude load this skill?"
  Include: ALWAYS trigger condition and one sentence distinguishing this from
  similar skills.
  Do NOT include usage instructions — those go in the skill body.]
user-invocable: true
disable-model-invocation: false
# Add context: fork only when the skill should run in an isolated context.
metadata:
  suite: b-skills
  runtime: claude
  execution: inline # inline | fork
---
```

**Required fields:**
- `name` — kebab-case, prefixed with `b-`
- `description` — <=80 words, trigger-focused only
- `user-invocable: true`
- `disable-model-invocation: false`
- `metadata.suite: b-skills`
- `metadata.runtime: claude`
- `metadata.execution: inline | fork`

**Supported optional fields:**
- `allowed-tools`
- `context`
- `agent`
- `model`
- `effort`
- `hooks`
- `paths`
- `license`

**Repo conventions:**
- Use `context: fork` when `metadata.execution: fork`.
- Do not keep the old compatibility field in skill frontmatter.
- Do not add restrictive `allowed-tools` until the skill's actual Claude tool boundary has been verified.

Use Claude Code-native fields to express runtime behavior directly, not as decorative metadata.

**Description rules:**
- Start with a one-line summary of what the skill does
- Include `ALWAYS invoke when...` with a short, intent-shaped condition
- End with one-clause disambiguation from the most similar skill
- Keep Vietnamese trigger words in `references/runtime-contract.md` routing aids rather than spamming every skill description with multilingual keyword lists
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

```

Each skill uses a single `SKILL.md` file by default. Add extra files (`reference.md`, `examples.md`, `scripts/`) only when they materially improve maintenance — for example, externalize long templates to `reference.md` so `SKILL.md` stays scannable under context pressure (see `skills/b-plan/reference.md`).

Target Claude-native runtime source layout:

```text
CLAUDE.md        # Claude maintainer guidance for this source repo
global/CLAUDE.md # concise always-on Claude memory installed to ~/.claude/CLAUDE.md
skills/          # 9 Claude-native b-* skill definitions
agents/          # custom agents for isolated delegated lanes
hooks/           # hook configs and helper scripts for enforceable policy
settings/        # managed Claude settings, permissions, MCP, and hook snippets
references/      # on-demand shared references that still earn their context cost
```

Forked skills must set both `context: fork` and `agent: <agent-name>` in skill frontmatter. The matching `agents/<agent-name>.md` file must define tool, permission, and memory boundaries, and preload the owning skill with the `skills` frontmatter field.

Current forked skill agent mapping:

| Skill | Agent |
|---|---|
| `b-plan` | `b-plan-agent` |
| `b-research` | `b-research-agent` |
| `b-review` | `b-review-agent` |
| `b-audit` | `b-audit-agent` |

Claude governance sources:

| Source | Purpose |
|---|---|
| `hooks/b-skills-guard.py` | SessionStart context plus Bash mutation guard |
| `settings/b-skills.settings.json` | Claude hook and permission settings template |

## Shared references

Top-level `references/*.md` files are allowed when two or more skills need the same checklist or pattern guidance.

- Keep them short, task-oriented, and reusable across skills.
- They may define optional conventions, such as glossary/domain-doc layouts, when adding a whole new skill would be overkill.
- If a current skill points at a shared reference, ensure `install.sh` syncs it into `~/.claude/references/b-skills/` or beside installed skills.
- Treat reference-file changes like runtime-facing guidance: keep `README.md` and `REFERENCE.md` aligned in the same commit.

---

## Skill file structure template

```markdown
---
name: b-example
description: >
  [<=80 words, intent + disambiguation. Do NOT include trigger keyword
  lists; those live in this maintainer guide and detailed references.]
user-invocable: true
disable-model-invocation: false
metadata:
  suite: b-skills
  runtime: claude
  execution: inline
---

# b-example

$ARGUMENTS

[1-2 sentence summary of what this skill does and why it exists.]

## Claude execution model
- User-invocable as `/b-example`.
- Execution: inline or forked context.
- Rationale: [why this skill should or should not isolate its context]

## When to use
- [Bullet list of scenarios]

## When NOT to use *(optional but recommended)*
- [Scenarios that should trigger a different skill instead]

## Tools required
- `bundle-name` (see `references/runtime-contract.md` §4)
- `bundle-name` *(optional, for [condition])*

Skills reference **MCP bundles** by name (e.g., `serena-symbol-toolkit`,
`gitnexus-radar`, `context7-docs`). Do not enumerate per-tool lists inside
the skill; the bundle definition in `references/runtime-contract.md` is the
source of truth, including session-init steps, fallback ladder, and
cost/approval caveats.

Fallbacks: reference `references/runtime-contract.md` MCP fallback ladder. Skills add
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
  or canonical approval ask — those live in global/CLAUDE.md,
  references/runtime-contract.md, hooks/settings, or agents.]
```

---

## MCP selection criteria

Skills declare MCP usage by referencing **bundles** summarized in installed `CLAUDE.md` and fully defined in `references/runtime-contract.md` §4 — not by enumerating individual tool names. Bundle definitions own session-init steps, fallback behavior, cost/approval caveats, and language-coverage caveats.

| Role | When to add | Example |
|---|---|---|
| **Primary** | Skill cannot function without it | `context7-docs` for `b-research` |
| **Secondary** | Skill uses it conditionally for a specific step | `context7-docs` in `b-debug` for API-misuse checks |
| **Optional** | Enhances quality but skill works without it | `gitnexus-radar` in any code-touching skill |

**Rules:**
- Never add a bundle just to increase coverage — every bundle must have a clear use case in the Steps section.
- Reference the bundle name. Do not paste the per-tool list into the skill; that list belongs in `references/runtime-contract.md` §4.
- Label each bundle in "Tools required" with its role: required vs `*(optional, for [condition])`*.
- Always include a `Graceful degradation:` line summarizing skill-specific fallback (the generic MCP fallback ladder lives in `references/runtime-contract.md` §4 and is not restated).
- Write skill prose to prefer the lightest capable tool. Do not force MCP-first behavior for exact strings, manifests, prose, small file reads, or other cases where native tools are cheaper and equally reliable.
- Do not list `*_unsafe` tool variants (e.g., browser code-execution) in skill workflows. Approval is required per-invocation; they are excluded from default toolkits.

**GitNexus-specific criteria:**
- GitNexus is always **optional radar** for this suite. It is never a primary dependency of any skill and never acts as the editing layer.
- Serena is **primary hands** for exact symbol discovery, source inspection, references, and symbol-aware edits.
- Add `gitnexus-radar` to a skill only when graph-level intelligence (cross-file impact, architecture context, execution-flow discovery, stale-index detection, route/API consumers, multi-repo mapping) materially improves the workflow. GitNexus is the preferred first step for graph-shaped tasks only when the repo is **indexed, fresh, and target-aware**; Serena then handles exact symbol inspection and edits.
- If the target symbol or file is already known, or the task is local to a single file/module, skip GitNexus and go straight to Serena.
- Every skill that uses GitNexus must rely on the freshness gate summarized in installed `CLAUDE.md` and fully defined in `references/runtime-contract.md` §4, then fall back to Serena/native tools when the gate fails.
- When both MCPs appear in one workflow, GitNexus answers the graph question first; Serena then becomes the source of truth for symbol lookup, body inspection, references, and edits. Do not keep both active on the same exact question.
- Before maintainers suggest `gitnexus analyze --skip-agents-md` or add indexing guidance to a skill, verify it is **only when indexing is safe**.

---

## File sync rules

All skills live in `skills/<name>/SKILL.md`. When changing skill files:

| Change type | Action |
|---|---|
| **Create** new skill | Create `skills/<name>/SKILL.md`; document any concrete Claude alias gap before adding non-skill entrypoints |
| **Update** skill | Edit `skills/<name>/SKILL.md`; if the change adds or modifies a long template/skeleton, externalize it to `skills/<name>/reference.md` and link from `SKILL.md` |
| **Delete** skill | Delete `skills/<name>/SKILL.md`, any `reference.md`/`examples.md`/`scripts/`, its agent if dedicated, and the directory if empty |

**Runtime contract sync** — when always-on Claude runtime behavior changes, update `global/CLAUDE.md`; when detailed schemas/rubrics/protocols change, update `references/runtime-contract.md`; when policy is enforceable, update hooks/settings instead of duplicating prose. Keep related repo docs aligned in the same commit.

**Root `CLAUDE.md`** — keep repo-level maintainer guidance in this root `CLAUDE.md` so Claude Code loads the source-repo authoring rules when working in this repository. Do not reintroduce a root `AGENTS.md`.

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
8. **No duplicated global concepts** — slug algorithm, status block, handoff envelope, manifest schema, approval ask, fallback labeling, tool-use heuristics, empty-state defaults, plan staleness gates, workspace isolation preference, review checkpoint cadence, completion closure protocol, and the DOM-unit vs browser boundary all live in `global/CLAUDE.md`, hooks/settings, or `references/runtime-contract.md`. Skills reference them; they do not restate them.
