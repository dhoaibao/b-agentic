#!/usr/bin/env python3
"""Check shared instruction contracts; these scenarios do not simulate live agent behavior."""

from __future__ import annotations

import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
# ADR-030, ADR-032: the canonical prompts carry at most this many runtime marker lines in all, so a
# runtime-adapted overlay stays thin instead of forking the prompts.
MARKER_BUDGET = 10
MARKER_LINE = ("<!-- runtime:", "<!-- /runtime")

# Each scenario names an observable instruction boundary, independent of tool spelling.
SCENARIOS = (
    ("main authority", "kernel", "The main session owns user-facing discussion, material decisions, worktree changes"),
    ("child authority", "kernel", "They do not edit, commit, question users, delegate, or perform mutations"),
    ("protected reads", "kernel", "never read, expose, or commit likely-secret files"),
    (
        "outside approval",
        "kernel",
        "protected/outside-project, or external/shared mutations even without a native prompt",
    ),
    (
        "unclassified MCP approval",
        "kernel",
        "Unclassified MCP tools require user approval even without a native prompt",
    ),
    ("review identity", "kernel", "A changed candidate needs fresh checks and a new review"),
    ("reviewer authority", "b-review", "is prohibited from editing"),
    (
        "recurring root cause",
        "b-review",
        "from round 2, before fixing a new blocker that shares a root cause with a blocker fixed in an earlier round, state your judgment, patch or change the design, with its reason; on a patch continue, and stop and ask the user before a design change",
    ),
    (
        "round cap diagnosis",
        "b-review",
        "When 3 consecutive `NEEDS FIXES` rounds stop the review, before asking, summarize those rounds' blockers grouped by root cause, name the groups that recurred across rounds",
    ),
    (
        "round cap choices",
        "b-review",
        "change the design, narrow the scope, defer with a recorded known limit, or keep patching",
    ),
    (
        "deferral pauses delivery",
        "b-review",
        "A deferral records the known limit and pauses delivery: the finding stays a blocker",
    ),
    (
        "flow round diagnosis",
        "b-flow",
        "At 3 consecutive `NEEDS FIXES`, ask with the round diagnosis and choices `b-review` names; a design change proposed for a blocker that shares a root cause with a fixed one is also a stop",
    ),
    (
        "flow fix-round judgment",
        "b-flow",
        "from round 2, first state `b-review`'s patch-or-design judgment",
    ),
    (
        "flow stop resume",
        "b-flow",
        "`unblock` works only on a `blocked` run: after a stop that left the run in its phase, continue there as the user's answer allows",
    ),
    (
        "plan check overlap",
        "b-plan",
        "Do not list a check whose work another listed check already covers, unless an `AC-n` or a repository rule needs that exact command",
    ),
    (
        "flow settled candidate",
        "b-flow",
        "settle the candidate first: every edit, docs included, done and its related checks passed",
    ),
    (
        "flow check order",
        "b-flow",
        "cheapest first and the heaviest last (a batch listed to run together counts as one check; `next` names what is owed, not the order to run it in)",
    ),
    (
        "flow fix batch checks",
        "b-flow",
        "Fix the whole batch, failed QA criteria included, and pass the checks related to it before `advance verify`; that narrow run is no plan check and never full coverage",
    ),
    ("review trigger", "kernel", "Require independent `b-review` review when requested by the user"),
    ("verification", "kernel", "run applicable required checks, and explain the observable result"),
    ("question answer", "b-implement", "Wait for the answer and re-evaluate"),
    ("commit authorization", "b-commit", "Require an explicit user commit request"),
    ("push authorization", "kernel", "run only on an explicit user PR request"),
    (
        "unclassified database tool approval",
        "b-datagrip",
        "they are unclassified and require user approval even without a native prompt",
    ),
    ("branch decision", "b-commit", "If the user declines or does not answer, stop without staging"),
    (
        "remote database confirmation",
        "b-datagrip",
        "Never run a write on a remote or production-like connection without a confirmation that names that connection",
    ),
)


# Managed Claude Code settings allow bare Edit/Write/Bash, so docs must not promise a native prompt.
DOC_SURFACES = (
    "REFERENCE.md",
    "README.md",
    "claude/configs/README.md",
    "docs/decisions/ADR-001-b-agentic-design-record.md",
    "docs/decisions/ADR-008-claude-code-only.md",
)
FALSE_PROMPT_CLAIMS = (
    "managed claude code rules ask for outside-project writes",
    "claude code prompts for outside-project writes",
    "outside-project writes prompt",
)


def validate_docs(docs: dict[str, str]) -> list[str]:
    errors = []
    for path, text in docs.items():
        flat = " ".join(text.lower().split())
        errors.extend(
            f"{path}: unsupported native-prompt claim: {claim}" for claim in FALSE_PROMPT_CLAIMS if claim in flat
        )
    return errors


def validate(runtime: str, texts: dict[str, str], skills: list[dict]) -> list[str]:
    errors = [
        f"{runtime}: {scenario} contract missing from {surface}"
        for scenario, surface, clause in SCENARIOS
        if clause not in texts[surface]
    ]
    for skill in skills:
        name = skill["name"]
        execution = skill["execution"]
        if execution["mode"] != "subagent":
            continue
        agent = execution["agent"]
        if f"`{name}` -> `{agent}`." not in texts["kernel"]:
            errors.append(f"{runtime}: routing contract missing for {name}")
        gate = skill.get("primary_gate")
        gate = gate if gate and runtime in gate["runtimes"] else None
        for clause in (
            f"`{name}` runs the {gate['label']} gate first, from the main session as the Steps direct;"
            if gate
            else f"`{name}` runs only in the `{agent}` subagent.",
            "never fall back to self-execution",
            "do not delegate again",
        ):
            if clause not in texts[name]:
                errors.append(f"{runtime}: delegation contract missing for {name}: {clause}")
        eligibility = ELIGIBILITY[runtime]
        if eligibility not in texts[name]:
            errors.append(f"{runtime}: profile eligibility missing for {name}")
    return errors


ELIGIBILITY = {
    "claude": "contains none of `Edit`, `Write`, `NotebookEdit`",
    "pi": "contains none of `edit`, `write`",
}


def marker_errors(sources: dict[str, str]) -> list[str]:
    """The runtime marker lines of the canonical sources must stay within the budget."""
    count = sum(1 for text in sources.values() for line in text.splitlines() if any(m in line for m in MARKER_LINE))
    if count > MARKER_BUDGET:
        return [f"markers: {count} runtime marker lines exceed the budget of {MARKER_BUDGET} (ADR-030)"]
    return []


def pi_texts(skills: list[dict]) -> dict[str, str]:
    """The Pi kernel and skills rendered in memory, as the installer renders them; nothing is written."""
    sys.path.insert(0, str(ROOT))
    from tooling.generate import registry_sync

    outputs, _ = registry_sync.render_pi_outputs(
        registry_sync.load_skills(), registry_sync.load_agents(), registry_sync.load_policy()
    )
    texts = {"kernel": outputs["kernel.md"]}
    texts.update({skill["name"]: outputs[f"skills/{skill['name']}/SKILL.md"] for skill in skills})
    return texts


def main() -> int:
    skills = json.loads((ROOT / "skills/registry.yaml").read_text())["skills"]
    errors: list[str] = []
    runtimes = (("claude", "references/kernel.template.md", "skills"), ("pi", "", ""))
    for runtime, kernel, directory in runtimes:
        if runtime == "pi":
            texts = pi_texts(skills)
        else:
            paths = {"kernel": ROOT / kernel}
            paths.update({skill["name"]: ROOT / directory / skill["name"] / "SKILL.md" for skill in skills})
            missing = [str(path.relative_to(ROOT)) for path in paths.values() if not path.is_file()]
            if missing:
                errors.append(f"{runtime}: missing parity surfaces: {', '.join(missing)}")
                continue
            texts = {name: path.read_text() for name, path in paths.items()}
        errors.extend(validate(runtime, texts, skills))
        # Mutating an instruction boundary must fail the matching scenario on the runtime.
        for scenario, surface, clause in SCENARIOS:
            candidate = {**texts, surface: texts[surface].replace(clause, "removed")}
            if not any(f": {scenario} contract missing" in error for error in validate(runtime, candidate, skills)):
                errors.append(f"{runtime}: parity regression did not detect missing {scenario}")
    sources = {str(path.relative_to(ROOT)): path.read_text() for path in sorted((ROOT / "skills").glob("*/prompt.md"))}
    sources["references/kernel.template.md"] = (ROOT / "references/kernel.template.md").read_text()
    errors.extend(marker_errors(sources))
    # The budget check must fail on one line over: add the missing lines to a copy and expect it to be caught.
    shipped = sum(1 for text in sources.values() for line in text.splitlines() if any(m in line for m in MARKER_LINE))
    over = {**sources, "regression": "\n".join("<!-- runtime: claude -->" for _ in range(MARKER_BUDGET - shipped + 1))}
    if not marker_errors(over):
        errors.append("markers: parity regression did not detect an over-budget marker count")
    doc_paths = [ROOT / path for path in DOC_SURFACES]
    missing_docs = [str(path.relative_to(ROOT)) for path in doc_paths if not path.is_file()]
    if missing_docs:
        errors.append(f"docs: missing parity surfaces: {', '.join(missing_docs)}")
    else:
        docs = {path: (ROOT / path).read_text() for path in DOC_SURFACES}
        errors.extend(validate_docs(docs))
        for claim in FALSE_PROMPT_CLAIMS:
            candidate = {**docs, DOC_SURFACES[0]: docs[DOC_SURFACES[0]] + "\n" + claim.replace(" ", "\n")}
            if not validate_docs(candidate):
                errors.append(f"docs: parity regression accepted unsupported native-prompt claim: {claim}")
    if errors:
        print("\n".join(errors), file=sys.stderr)
        return 1
    print("Runtime instruction parity checks passed (Claude Code and Pi; live behavior unverified).")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
