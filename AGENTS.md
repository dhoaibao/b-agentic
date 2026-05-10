# b-skills — Repo conventions & skill authoring

Guidelines for creating, editing, and maintaining the install-only OpenCode skill suite in this repository.

## Scope

- This file is maintainer guidance for the source repository.
- Runtime suite behavior lives in `global/AGENTS.md` and the individual `skills/*/SKILL.md` files.
- `install.sh` deploys the runtime files into `~/.config/opencode/`.

## Quick links

- `skills/b-plan/SKILL.md` — Task decomposition and planning
- `skills/b-research/SKILL.md` — Library docs and multi-source research
- `skills/b-implement/SKILL.md` — Approved-plan execution
- `skills/b-debug/SKILL.md` — Hypothesis-driven debugging
- `skills/b-review/SKILL.md` — Pre-PR code review
- `global/AGENTS.md` — Runtime rules source installed as OpenCode's global `AGENTS.md`
- `commands/` — Thin slash-command wrappers that load the matching skills

---

## Frontmatter spec

Every `skills/<name>/SKILL.md` must begin with YAML frontmatter:

```yaml
---
name: b-skill-name
description: >
  [Trigger-focused description, <=80 words. Answer only: "when should OpenCode load this skill?"
  Include: ALWAYS trigger condition, key Vietnamese + English trigger phrases,
  and one sentence distinguishing this from similar skills.
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
- Include `ALWAYS invoke when...` with specific trigger phrases
- Include both Vietnamese and English trigger keywords
- End with disambiguation from the most similar skill
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

For this repo, each skill currently uses a single `SKILL.md` file plus a thin command wrapper. Add extra files only when they materially improve maintenance.

---

## Skill file structure template

```markdown
---
name: b-example
description: >
  [<=80 words, trigger-focused]
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
- `tool_name` — from `mcp-server` MCP server
- `tool_name` — from `mcp-server` MCP server *(optional, for [condition])*

If [MCP] is unavailable: [what to do — stop, fallback, or degrade]

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
- [Bullet list of constraints and guardrails]
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

When deciding which MCPs a skill should use:

| Role | When to add | Example |
|---|---|---|
| **Primary** | Skill cannot function without it | brave-search for b-research |
| **Secondary** | Skill uses it conditionally for a specific step | context7 for b-research (HOWTO queries only) |
| **Optional** | Enhances quality but skill works without it | sequential-thinking for b-review |

**Rules:**
- Never add an MCP just to increase coverage — every MCP must have a clear use case in the Steps section
- Always document what happens when an optional/secondary MCP is unavailable
- Label each MCP in "Tools required" with its role: required vs `*(optional, for [condition])*`
- Always include a `Graceful degradation:` line summarizing fallback behavior

---

## File sync rules

All skills live in `skills/<name>/SKILL.md`. When changing skill files:

| Change type | Action |
|---|---|
| **Create** new skill | Create `skills/<name>/SKILL.md` and `commands/<name>.md` |
| **Update** skill | Edit `skills/<name>/SKILL.md` and keep `commands/<name>.md` aligned |
| **Delete** skill | Delete `skills/<name>/SKILL.md`, `commands/<name>.md`, and the directory if empty |

**`global/AGENTS.md` sync** — when runtime behavior changes, update `global/AGENTS.md` in the same commit and keep any related repo docs aligned.

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
3. **Every fallback path is explicit** — if a tool is unavailable, the skill says exactly what to do (stop, degrade, or use alternative)
4. **Inter-skill handoffs have trigger conditions** — "if [condition] -> use /b-[other]" with the specific condition, not just "consider using"
5. **No trigger keyword regression** — before rewriting a description, list all current trigger keywords and verify all survive in the new version

---

## New skill creation guide

### Folder structure

```text
b-skills/
├── AGENTS.md                # Repo-level maintainer guidance
├── commands/
│   └── b-example.md
├── global/
│   └── AGENTS.md            # Runtime rules source installed as OpenCode's global AGENTS.md
├── skills/
│   └── b-example/
│       └── SKILL.md
├── install.sh
├── README.md
└── REFERENCE.md
```

### Naming convention

- `name` field: `b-[verb-or-noun]` in kebab-case
- Examples: `b-plan`, `b-docs`, `b-research`, `b-debug`
- Keep names short (1-2 words after `b-`)

### How to add a new skill

1. Create `skills/<name>/SKILL.md` with valid OpenCode frontmatter (`name` + `description`)
2. Create the matching `commands/<name>.md` wrapper
3. `install.sh` picks both up automatically — no script changes needed
4. Update `README.md` skills overview table and install/source-layout notes
5. Update `REFERENCE.md` with a detailed reference section
6. Run `install.sh` to deploy the updated suite into the correct OpenCode paths

### How to add a new MCP to the suite

1. Add the MCP to the `MCP dependencies` table in `README.md`
2. In each skill that uses it, add it to the "Tools required" section with a role label
3. Update the docs that mention the expected MCP set size
4. Document graceful degradation for every skill that uses the new MCP
