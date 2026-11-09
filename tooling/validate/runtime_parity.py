#!/usr/bin/env python3
"""Check shared instruction contracts; these scenarios do not simulate live agent behavior."""

from __future__ import annotations

import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]

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
    "docs/decisions/ADR-005-opencode-restored.md",
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
        gate = gate if gate and gate["runtime"] == runtime else None
        for clause in (
            f"`{name}` runs the {gate['label']} gate first, from the main session as the Steps direct;"
            if gate
            else f"`{name}` runs only in the `{agent}` subagent.",
            "never fall back to self-execution",
            "do not delegate again",
        ):
            if clause not in texts[name]:
                errors.append(f"{runtime}: delegation contract missing for {name}: {clause}")
        eligibility = (
            "denies `edit`, `subagent`, `question`"
            if runtime == "opencode"
            else "contains none of `Edit`, `Write`, `NotebookEdit`"
        )
        if eligibility not in texts[name]:
            errors.append(f"{runtime}: profile eligibility missing for {name}")
    return errors


def main() -> int:
    skills = json.loads((ROOT / "skills/registry.yaml").read_text())["skills"]
    errors: list[str] = []
    for runtime, kernel, directory in (
        ("claude", "references/kernel.template.md", "skills"),
        ("opencode", "opencode/configs/kernel.md", "opencode/skills"),
    ):
        paths = {"kernel": ROOT / kernel}
        paths.update({skill["name"]: ROOT / directory / skill["name"] / "SKILL.md" for skill in skills})
        missing = [str(path.relative_to(ROOT)) for path in paths.values() if not path.is_file()]
        if missing:
            errors.append(f"{runtime}: missing parity surfaces: {', '.join(missing)}")
            continue
        texts = {name: path.read_text() for name, path in paths.items()}
        errors.extend(validate(runtime, texts, skills))
        # Mutating an instruction boundary must fail the matching scenario on each runtime.
        for scenario, surface, clause in SCENARIOS:
            candidate = {**texts, surface: texts[surface].replace(clause, "removed")}
            if not any(f": {scenario} contract missing" in error for error in validate(runtime, candidate, skills)):
                errors.append(f"{runtime}: parity regression did not detect missing {scenario}")
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
    print("Runtime instruction parity checks passed (two runtimes; live behavior unverified).")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
