---
name: b-audit
description: >
  Read-only whole-project audit of the current repository across
  correctness/security defects, dependency currentness, architecture and
  boundary drift, test and verification gaps, and docs/instruction drift,
  with evidence thresholds and approval-gated advisory scans. Unlike
  b-agentic-audit, it audits any repository against its own documented
  standards.
argument-hint: "[scope or dimensions]"
metadata:
  phase: Validate
  execution_mode: subagent
  agent: b-auditor
---

<!-- Generated from skills/registry.yaml and skills/b-audit/prompt.md. Edit those sources, not this file. -->

# b-audit

Run a read-only, source-based audit of the current repository across the dimensions the user names (all five by default):

1. **Correctness and security defects** — concrete defects with a reachable path or explicit code evidence.
2. **Dependency currentness** — local pins and installed versions against bounded primary upstream evidence.
3. **Architecture and boundary drift** — the code against the repository's own documented boundaries (AGENTS.md, CLAUDE.md, README, ADRs).
4. **Test and verification gaps** — untested critical paths and documented checks that are missing or failing.
5. **Docs and instruction drift** — commands, paths, and claims in docs that no longer match the repository.

This audit supplements the repository's own checks; it does not mechanically prove prose semantics and never substitutes for changed-code `b-review`.

## Delegation boundary

`b-audit` runs only in the `b-auditor` subagent.

- Main session: reading this file prepares the handoff; it never authorizes running the steps below yourself. Gather the parent-owned evidence and confirm the effective `b-auditor.md` (project `.claude/agents/` over `~/.claude/agents/`) is readable and its parsed frontmatter `tools` value, normalized to a list (comma-separated scalar or YAML sequence), is explicit, non-empty, and contains none of `Edit`, `Write`, `NotebookEdit` (a missing, blank, or null `tools` grants every tool), then call the `Agent` tool with `subagent_type` `b-auditor` and a bounded task naming `b-audit`. Do not do this skill's work with your own tools, even for a quick, small, or single-lookup request. If the subagent is unavailable or fails, or its result notes an unknown agent type or `general-purpose` fallback (discard that result), report the gap and ask the user; never fall back to self-execution. Evaluate the returned result before any user-facing or worktree action.
- `b-auditor` child: execute the steps below read-only, return this skill's Output format to the main session, and do not delegate again.

Parent-owned evidence to gather and pass to the child (or state what is unavailable):

- after approved origin fetch, branch/upstream and HEAD ahead/behind counts (both zero required)
- status, user-named scope and dimensions, paths of the repo's own instruction/decision docs (AGENTS.md, CLAUDE.md, README, ADRs), and output of its documented verification commands; manifest/lockfile names and installed versions when available; approved advisory-scan output when run

User arguments for the bounded task: $ARGUMENTS

## Mandatory origin freshness gate

Before any other audit step or repository read, require the main session to supply its completed origin-freshness evidence:

1. The main session refreshes local remote-tracking metadata and resolves the current branch and its configured `origin/*` upstream without pull, merge, rebase, or working-tree modification.
2. It supplies the metadata-only comparison of `HEAD` with that upstream and its ahead/behind counts. Proceed only when both counts are zero.
3. If the evidence is missing, the branch is detached, the `origin` ref is missing, the metadata-only branch comparison fails, or the branch is ahead, behind, or diverged, report only: `BLOCKED: current branch is not up to date with origin; synchronize it and rerun the audit.` Do not read audit sources, run audit checks, perform currentness probes, or issue normal findings or a verdict.

## When to use

- The user requests a project, codebase, or whole-repository audit, or an audit limited to selected dimensions.
- A pre-release or handover health check of the current repository needs evidence-backed findings.

## When NOT to use

- A b-agentic repository or design-conformance audit -> **b-agentic-audit**.
- Reviewing a working-tree, staged, or commit-range diff -> **b-review**.
- Diagnosing a runtime failure -> **b-debug**.
- External facts only -> **b-research**.
- Acceptance criteria of a reviewed candidate -> **b-qa**.
- Fixing findings -> **b-frontend** for frontend/UI changes, **b-implement** for other production changes, or **b-refactor** for a named behavior-preserving transform.
- An unclear audit scope -> **b-plan**.

## Tool guidance

- Read-only shell commands (for example `git status`, `git diff`, `rg`) inspect repository evidence; run nothing that mutates. Use the main session's supplied status and documented-check output, and state an explicit evidence gap when a required check cannot be run read-only.
- Native `Read` inspects the repository's own instruction and decision docs and the sources they cite; prefer sources over generated assets.
- Never run registry-contacting commands (`npm audit`, `pip-audit`, `osv-scanner`, `npm outdated`, or similar): they send manifest data off the machine. Ask the main session to obtain the user's approval and supply the output; report dependency advisories as unverified without it.
- `context7` or bounded primary upstream documentation and release metadata verify versioned currentness using public package names only; never upload repository content, credentials, or private URLs.
- Read nothing outside the project and no likely-secret file (`.env`, `*.pem`, `credentials.*`, `secrets.*`) without explicit approval.
- `codegraph` - select when a concrete architecture, impact, or affected-test question is central and an index exists; report an absent index as a gap. Spanning files alone never justifies it.
- `python3 -I -B ~/.claude/b-agentic/bin/b_run.py runs` is read-only: run it once, after the freshness gate, to count the local `.b-agentic/runs` folders. Report it as a housekeeping note, never a finding: it does not change a severity or the verdict. When `over_threshold` is true, add one follow-up with the run count and size that recommends the main session list the old finished runs with `b_run.py prune` and ask the user before `prune --apply`; otherwise one checked-and-clean line. A missing folder or helper is a one-line note, not an evidence gap. Never run `prune`.

## Steps

1. Confirm the main session's origin-freshness and status evidence before reading repository files. If it is incomplete, report the blocking message only.
2. Fix the scope and dimensions from the request, and state exclusions.
3. Read the repository's own instructions, decision records, and manifests as the yardstick. When they are missing, report dimensions 3 and 5 as unverifiable; never invent conventions.
4. Defects: report a concrete defect with `path:line`, trigger, and impact. A security finding needs a reachable path or explicit code evidence.
5. Currentness: resolve local pins and installed versions, then use bounded primary upstream evidence; report currentness as unverified when evidence is unavailable.
6. Architecture: cite the documented boundary and the violating source.
7. Tests and verification: use the supplied output of the documented commands and name untested critical paths; make no coverage claim without data.
8. Docs: list commands, paths, and claims that do not match the repository.
9. Separate deterministic results from semantic findings. Order findings by severity and cite repository-relative paths, evidence, impact, and the smallest follow-up route. State what was not mechanically proven.
10. Record needed changes as follow-up.

## Output format

Findings (ordered by severity), per-dimension comparison, automated checks, checked-and-clean areas, currentness and advisory-scan status, residual limitations, and follow-up. If the freshness gate fails, report the blocked notification only and do not emit the normal findings or verdict. Otherwise, the response must end with exactly one standalone final line, with no text after it, which is one of:

- `Verdict: NEEDS FIXES` when there is an actual defect, safety issue, failing documented check, or documented-boundary drift.
- `Verdict: READY WITH FOLLOW-UPS` when only non-blocking findings exist (outdated dependencies, test gaps, docs drift), or when required currentness, advisory-scan, or documented-check evidence is unavailable or unverified.
- `Verdict: READY FOR PR` only when all required dimensions and evidence are verified.

## Rules

- Keep the audit strictly read-only: do not edit, stage, commit, push, run mutating commands, or apply fixes.
- A missing, failed, or non-zero origin-freshness comparison is a blocked audit, not a finding; return the blocking message to the main session and stop without auditing or issuing a verdict.
- Make no finding from file size, export count, or style preference alone; a performance finding needs a measured hotspot or explicit algorithmic evidence.
- Prefer repository evidence over assumptions and cite repository-relative paths; never treat generated assets as canonical when a source exists.
- Do not claim that passing checks prove health, currentness, or the absence of drift.
- Do not transmit repository or private data or credentials for currentness checks, and do not expose credentials, token values, private URLs, or raw operational errors.
- Do not use this skill as a generic code-diff review; independent review of a frozen changed candidate belongs to **b-review**.
