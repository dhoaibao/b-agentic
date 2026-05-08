---
name: b-plan
description: >
  Think before coding. Decompose non-trivial tasks into ordered steps, evaluate approaches,
  surface risks, and produce an execution-ready plan file. ALWAYS invoke when the user says
  "plan", "thiết kế", "how should I approach", "lên kế hoạch", "nên bắt đầu từ đâu",
  or the task spans more than 2 files or has unclear scope.
  Unlike b-debug (fix broken) or b-research (lookup info), b-plan owns the decision of
  what to build and in what order.
effort: high
---

# b-plan

$ARGUMENTS

Think before coding. Lock scope, evaluate approaches, decompose into ordered steps,
surface risks and unknowns, then produce a clear plan file before any implementation.

If `$ARGUMENTS` is provided, treat it as the task description — skip asking "what do you want to build?" and proceed directly with the stated task. Ask only for missing context (constraints, greenfield vs existing, issue URL).

## When to use

- Task involves more than 2 files or multiple layers (API, DB, service, UI).
- Task has unclear scope or multiple valid approaches — need a decision.
- User is about to implement something non-trivial and hasn't thought through the order.
- Refactoring, architecture changes, or new feature integration.
- User says: "plan", "thiết kế", "how should I approach X", "lên kế hoạch", "nên bắt đầu từ đâu".

## When NOT to use

- Simple single-file edit or ≤2-step task → do it directly.
- Something is broken → use **b-debug**.
- Quick fact or library lookup → use **b-research**.
- Mechanical refactoring with a clear target already defined → use **b-refactor**.

## Tools required

- `sequentialthinking` — from `sequential-thinking` MCP server *(optional, for approach evaluation and decomposition when available)*.
- `check_onboarding_performed`, `onboarding`, `find_symbol`, `get_symbols_overview`, `find_referencing_symbols`, `rename_symbol` — from `serena` MCP server *(required for symbol-aware modify-existing-code tasks; optional for greenfield)*.
- `resolve-library-id`, `query-docs` — from `context7` MCP server *(optional, for inline library verification — simple lookups only)*.
- `brave_web_search` — from `brave-search` MCP server *(optional, for tool/approach comparison — simple lookups only)*.
- `firecrawl_scrape` — from `firecrawl` MCP server *(optional, for scraping issue/ticket URL when present)*.

If sequential-thinking is unavailable: reason inline as `Goal → Constraints → Options → Decision → Ordered steps → Open questions`.
If Serena is unavailable: use Bash search and `Read` for narrow code inspection. Note: "⚠️ Serena unavailable — cross-file tracking incomplete."
If context7 or brave-search is unavailable: delegate to /b-research.
If firecrawl is unavailable: store issue URL as a plain reference without scraping.

Graceful degradation: ✅ Possible — core planning works without MCPs using inline reasoning plus Bash/Read.

## Steps

### Step 0 — Mode select

Choose the lightest mode that fits the task before any other work.

- **Quick mode** — scoped daily tasks: clear end state, low risk, usually ≤2 files, no DB/schema migration, no public API contract change, no security-sensitive behavior. Output a concise 2–5 step chat plan with a verification step. After approval, implementation may proceed in the same session.
- **Full mode** — unclear, high-risk, multi-layer, or >2-file work. Run all steps below and write a plan file to `.claude/b-plans/`.

**Selection rule**: choose yourself from task complexity; do not ask the user. Announce the chosen mode in one sentence and why. Ask only when both modes are genuinely valid and preference matters.

**Escalate quick → full** when discovery reveals broad references, unclear requirements, a structural decision, external API uncertainty, or deployment risk.

Broad or unclear refactors stay with `b-plan` until reduced to concrete mechanical transformations that can be handed off to `b-refactor`.

In quick mode: skip Steps 2–6 unless escalation triggers; produce the chat plan, ask for approval, then proceed.

---

### Step 1 — Scope lock

Confirm what is being built before scanning any code.

**If the task is clearly scoped** (user already described the full feature, no ambiguity):
- Restate the scope in one sentence and ask the user to confirm.
- Note greenfield vs existing — if existing → continue to Step 2; if greenfield → skip Step 2.

**If the task has unclear scope**:
- Ask the three scope questions:
  - **What is the end state?** What does "done" look like exactly?
  - **What are the hard constraints?** Performance, compatibility, deadlines, must-not-break areas.
  - **What does success look like?** 2–4 concrete, verifiable criteria.
- Ask once. If still unclear, ask one focused follow-up. Don't loop.

**Unknown-ask rule** *(enforced throughout all steps)*: any requirement or decision that cannot be determined from the task or codebase — behavioral choice, priority, integration contract, naming — must be asked to the user immediately. Never self-infer or assume. Surface unknowns as discovered; batch per step if multiple arise.

**Decision accumulation** *(running record across all steps)*: each time a user answer, codebase finding, or approach choice settles a behavioral or design question, record it as a numbered confirmed decision. Compile into `## Confirmed decisions` in the plan. Format each entry as a single, unambiguous, implementation-actionable statement — no hedging, no "consider", no "may". Example: `"Realtime update must update the existing VoiceCall matched by VendorCallKey; if soft-deleted, insert a new row instead."`

**Feasibility check** *(inline when scope is non-trivial)*:
- Does the current architecture support this? Use Serena symbol discovery and reference tracing where supported; native Read/Bash for prose, config, and exact strings.
- Any blockers? (Missing infrastructure, incompatible dependencies, architectural gaps.)
- Effort estimate: S (hours) / M (1–2 days) / L (3–5 days) / XL (1–2 weeks) / XXL (weeks+).
- If blockers found: state clearly. If no workaround exists, do not proceed until resolved.
- If the task looks XL–XXL and depends on an unfamiliar pattern or unverified library, stop and run /b-research first.

---

### Step 2 — Scan existing code *(existing-code tasks only)*

Use Serena for supported symbol-aware discovery before planning. Follow this exact order:

1. **Initialize project knowledge** — call `check_onboarding_performed`. If false, call `onboarding` once.
2. **Discover symbols** — `find_symbol` on the main function, class, command, handler, or module involved in the change.
3. **Inspect structure** — `get_symbols_overview` on each relevant file to see which symbols are worth reading.
4. **Trace references** — `find_referencing_symbols` on key exported/shared symbols to confirm callers and dependents.
5. **Read narrowly** — only if the above leaves ambiguity: native `Read` on the exact section needed; native Bash search for exact strings.

**Issue/ticket** *(optional context source — runs here if relevant)*:
- Ask once: "Issue/ticket URL or ID? (Leave blank to skip.)"
- If a URL is provided: `firecrawl_scrape` with `formats: ["markdown"], onlyMainContent: true`. Trim to 800 words; use as **requirements context** for Steps 3–5. If <200 chars or 403: store the URL as a plain reference.
- If a ticket ID (not URL): store as-is; no fetch.

**Goal**: reference real paths and symbols. A plan that names wrong files or non-existent functions fails at execution. Never paste full file contents into the plan — only names and line references that matter.

---

### Step 3 — Evaluate approaches *(conditional)*

Run if the task has a structural decision: new module vs extending existing, sync vs async, REST vs event-driven, library A vs B.

1. List 2–3 viable approaches with key trade-offs (complexity, performance, coupling, reversibility).
2. Use `sequentialthinking` to evaluate them against the current constraints.
3. Make the reasoning useful for execution: chosen approach, alternatives rejected, the assumption that could flip the decision, the first implementation step.
4. Pick one and document in `## Decision`.
5. Add the approach choice and structural trade-offs to the running confirmed decisions list.

Skip this step if the approach is already obvious — do not invent choices where none exist.

---

### Step 4 — Decompose

Use `sequentialthinking` to break the chosen approach into atomic, ordered steps:

- Each step: independently executable, independently verifiable.
- Ordered by dependency — not by what's easiest.
- Usually 4–8 steps. Split into phases if >10.
- Each step answers: *what*, *why now*, *done when* — and must include:
  - **Exact file paths** and **symbol names** (e.g. `src/auth/middleware.ts:validateToken()`).
  - **Current state** of anything being changed.
  - **Concrete done-when** verifiable independently (test command, observable output, specific assertion).
  - Any **API signatures**, **config keys**, or **contract details** needed to implement without further lookup.
  - **`Exact [X]:`** sub-bullets for any implementation choices that must be locked in to prevent implementor drift — e.g. `Exact insertion points:`, `Exact helper responsibilities:`, `Exact fields to create:`. Add whenever the step would otherwise leave a structural decision open.
- **Handoff standard: 90%+** — if a fresh agent with zero prior context would need to ask a follow-up question to implement the step, the step is not detailed enough. Add the missing detail now.
- Ask sequentialthinking for output in this shape: `Goal`, `Constraints`, `Ordered steps`, `Dependencies`, `Open questions`, `First action`.

**Impact checkpoint** *(modify-existing-code only)*:
- `find_referencing_symbols` on the main symbol/module being changed.
- `rename_symbol` only when the plan explicitly includes a rename of an exported/public symbol; call out broad references as migration risk.
- Wide downstream impact → split into smaller phases or add rollback steps.

**Deploy safety** — annotate any step that matches:
- New routes/endpoints → `⚠️ consider feature flag`
- DB schema changes → `⚠️ deploy order: [before / after] app deploy`
- New external service calls → `⚠️ verify availability in target environment`

**Planned touch points** — after decomposing, compile `## Planned touch points`: one bullet per file/class that will change, with the exact path and what is added/changed/removed at method or field level.

**Mapping/contract table** *(conditional — only when the task involves field mapping, data transformation, or protocol contracts)*: produce `## Mapping outline` listing every source → target mapping with repo field names, types, and normalization notes.

---

### Step 5 — Identify unknowns

Flag anything unresolved before handing off:

| Type | Action |
|---|---|
| **User decision** — behavioral choice, priority, integration contract, naming, or anything the codebase can't answer | ⛔ Stop. Ask the user immediately. Do NOT write the plan until resolved. |
| **Tech lookup** — library API behavior, yes/no capability, 2-option comparison | Resolve inline: `query-docs` (context7) or `brave_web_search`. Append `→ Confirmed: [finding]`. |
| **Complex research** — multi-source or open-ended comparison | Delegate to /b-research. Mark as `Unknown — needs /b-research: [topic]`. Do NOT block the plan on this. |

**Clarification gate** — before Step 6, batch all outstanding user-decision unknowns into a single message and wait for answers. Only write the plan after every user-decision unknown is resolved.

---

### Step 6 — Write plan

**Quick mode**: keep the plan in chat unless the user asks for a saved plan. Present the step list, ask for approval. After approval, implementation may proceed in the same session.

**Full mode**: write to `.claude/b-plans/[task-slug].md` in the **current project root only**.

- `task-slug` = kebab-case, e.g. `add-retry-logic`, `refactor-auth-module`.
- Create `.claude/b-plans/` if it doesn't exist.
- Show the exact saved path after writing.

Present a short summary (scope + step count) and ask for confirmation. Update and re-confirm if the user requests changes. After approval, implementation may proceed in the same session unless the user wants a separate handoff.

---

## Output format

Always English, regardless of the user's query language.

```markdown
# Plan: [task name]

**Scope**: [one sentence]
**End state**: [what "done" looks like]
**Created**: [date]
**Issue**: [URL, ticket ID, or omit entirely]

## Feasibility *(only if assessed in Step 1)*
**Effort**: [S/M/L/XL/XXL]
**Blockers**: [none / description]
**Assumptions confirmed**: [list]

## Decision *(only if multiple approaches were evaluated)*
**Chosen approach**: [what was selected]
**Alternatives rejected**: [option — reason]; [option — reason]
**Why**: [1–2 sentence rationale]

## Confirmed decisions
1. [Unambiguous, implementation-actionable statement.]
2. ...

## Mapping outline *(only if task involves field mapping or protocol contracts)*
- `[source field]` → `[target field]` — [normalization notes]
...

## Planned touch points
- `[exact/path/to/File.ext]` — [what is added / changed / removed, at method or field level]
...

---

## Steps

- [ ] 1. [Step name]
  - What: ... *(exact file path + symbol name)*
  - Current state: ... *(what exists today that will change)*
  - Why now: ...
  - Done when: ... *(verifiable by a fresh agent — test command, output, assertion)*
  - Exact [X]: ... *(optional — lock in implementation choices)*

- [ ] 2. [Step name]
  ...

## Dependencies
- Step 3 requires Step 1 to be complete
- Steps 4 and 5 can run in parallel

## Risks
- [Risk]: [mitigation or fallback]

## Unknowns *(resolve before starting)*
- Need /b-research: [topic] — [what to verify]
- Need decision: [question for user]
- Assuming: [assumption that may not hold]
```

---

## Rules

- Full mode must write to `.claude/b-plans/` — never leave full-mode plans only in chat.
- Quick mode may stay in chat unless the user asks for a saved plan.
- Always write saved plan files in English.
- Do not implement until the user approves the plan. After approval, implementation may proceed in the same session.
- Steps must be ordered by dependency — wrong order causes cascading failures.
- Keep steps atomic — one clear action per step.
- Surface risks and assumptions proactively.
- Split into phases if 10+ steps.
- Never trigger destructive git commands.
- **Never self-infer ambiguous requirements** — ask the user immediately.
- **Handoff standard: 90%+** — every step must be detailed enough that a fresh agent with zero prior context can implement it without asking a follow-up question.
