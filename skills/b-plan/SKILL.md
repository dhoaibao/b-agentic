---
name: b-plan
description: >
  Turn goals into execution-ready plans. Handles both underspecified
  requests and fuzzy problem statements by investigating enough to compare
  options, choose a path, and write ordered steps. Unlike b-implement,
  b-plan does not change code. Routing signals: plan, decompose, approach,
  explore, not sure, figure out, "how should I", implementation plan,
  clarify, requirements, scope. Delegated: runs only in the `b-planner`
  subagent; the main session never executes it itself.
argument-hint: "[goal or problem]"
metadata:
  phase: Decide
  execution_mode: subagent
  agent: b-planner
---

<!-- Generated from skills/registry.yaml and skills/b-plan/prompt.md. Edit those sources, not this file. -->

# b-plan

Turn an unclear goal into the smallest execution-ready plan. Do not implement.

## Delegation boundary

`b-plan` runs only in the `b-planner` subagent.

- Main session: reading this file prepares the handoff; it never authorizes running the steps below yourself. Gather the parent-owned evidence and confirm the effective `b-planner.md` (project `.claude/agents/` over `~/.claude/agents/`) is readable and its parsed frontmatter `tools` value, normalized to a list (comma-separated scalar or YAML sequence), is explicit, non-empty, and contains none of `Edit`, `Write`, `NotebookEdit` (a missing, blank, or null `tools` grants every tool), then call the `Agent` tool with `subagent_type` `b-planner` and a bounded task naming `b-plan`. Do not do this skill's work with your own tools, even for a quick, small, or single-lookup request. If the subagent is unavailable or fails, or its result notes an unknown agent type or `general-purpose` fallback (discard that result), report the gap and ask the user; never fall back to self-execution. Evaluate the returned result before any user-facing or worktree action.
- `b-planner` child: execute the steps below read-only, return this skill's Output format to the main session, and do not delegate again.

Parent-owned evidence to gather and pass to the child (or state what is unavailable):

- goal, constraints, non-goals, known decisions and prior findings; branch, HEAD, ahead/behind, and git status baseline; state gaps rather than asking the child to guess history

User arguments for the bounded task: $ARGUMENTS

## When to use

- The user asks for a plan, approach, decomposition, or requirements clarification.
- Scope, acceptance criteria, risk, sequencing, or constraints are unclear.

## When NOT to use

- A small clear non-UI change whose expected behavior and verification are already stated, or that changes no behavior -> **b-implement**. A change with unspecified expected behavior and no confirmed `AC-n` criteria stays here.
- Clearly scoped frontend/UI work -> **b-frontend**.
- External facts are the blocker -> **b-research**.
- A runtime failure needs diagnosis -> **b-debug**.

## Tool guidance

- Use native `read` and local search for routine evidence. Per the kernel CodeGraph rule, use it for affected symbols, callers, and tests in indexed code. When one versioned external library/API fact decides between viable options, one Context7 lookup (resolve once, query once) using only public library names and symbols is permitted; otherwise list it as an open **b-research** item. Use only planning context supplied in the current task; report missing history rather than guessing.

## Steps

1. State the interpreted goal, constraints, non-goals, and success criteria.
2. Inspect only the local evidence needed to avoid guessing. Use CodeGraph for affected symbols, callers, and tests when an index is available; otherwise report the fallback gap to the main session.
3. For non-trivial or risky work, compare viable paths and relevant quality dimensions, including the simpler option, then recommend the smallest safe one with evidence-backed rationale and accepted trade-offs. Name each materially considered option you reject with a one-line reason, so it is not re-proposed later. Keep small obvious tasks free of forced comparison or research.
4. Specify ordered implementation steps, affected paths/symbols, invariants, and `Done when` verification that proves observable behavior. When the work changes observable behavior or the request is ambiguous, also return a **Behavior delta**: current behavior with `file:line` or command evidence (label unverified inference as such), new behavior, 2–5 concrete input -> output examples, non-goals, and open questions; plus numbered criteria `AC-n: WHEN … THEN …`, each with an evidence type (automated, browser, ci, inspection, user-confirmed) and an exact existing command or, for inspection and user-confirmed evidence, a precise source. A criterion with neither is a gap; never invent a command. Skip the delta when no behavior changes or the request already states the exact expected behavior, target, and verification. Name the conditions under which the implementer must stop and ask (for example, a precondition fails or a step needs a path outside the stated scope) rather than improvise.
5. For a material user-facing decision, state 2–4 concrete options and their trade-offs for the main session to resolve with the user. Do not invoke `AskUserQuestion` or claim approval.
6. Return the plan to the main session with scope, acceptance, affected paths, invariants, verification, risks, and open items. The main session owns approval and any later implementation. When a Behavior delta is returned, the main session confirms it and the `AC-n` criteria with the user before implementation starts.
7. For changed work, include applicable checks and the kernel's risk classification of the final candidate: a bounded, verified low-risk change may finish without independent review, with direct tests/docs and faithfully regenerated outputs counted with their source; a triggered change must freeze the exact tracked plus relevant untracked/derived snapshot after fresh checks and obtain independent **b-review** review. This is not authorization to commit or push.

## Output format

Concise scope, recommended path, ordered steps, verification, explicit blockers, and unresolved decisions for the main session. Include the Behavior delta and `AC-n` criteria when step 4 triggers them. For a `/b-flow` run, also end with one fenced `json` block `{"spec": …, "plan": …}` in the shapes `python3 -I -B ~/.claude/b-agentic/bin/b_run.py schema spec` and `schema plan` print, checked with `b_run.py lint spec` and `lint plan` (read-only, so you may run them); the main session writes them with `b_run.py write`.
For a `/b-flow` run the plan may also list `worker_steps`, each applied by one `b-worker` while the main session waits: only self-contained steps with their own paths and a `done_when` check a fresh child can run, no open decision, no generated output or install, and more reading and editing than a child's reload costs. Never in a quick run; leave it out when unsure, and name each listed step so the approval round confirms it.

## Rules

- Do not implement.
- Keep plans short unless risk requires detail.
- Do not invent behavior, names, acceptance criteria, or commands.
- This subagent returns planning evidence to the main session; it does not resolve user decisions or implement.
