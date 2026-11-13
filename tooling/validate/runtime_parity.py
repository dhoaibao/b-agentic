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
        eligibility = ELIGIBILITY[runtime]
        if eligibility not in texts[name]:
            errors.append(f"{runtime}: profile eligibility missing for {name}")
    return errors


ELIGIBILITY = {
    "claude": "contains none of `Edit`, `Write`, `NotebookEdit`",
    "pi": "contains none of `edit`, `write`",
}


def shell_patterns(rules: list[str]) -> set[str]:
    """The shell patterns inside a Claude Code rule list's `Bash(...)` entries."""
    return {rule.removeprefix("Bash(").removesuffix(")") for rule in rules if rule.startswith("Bash(")}


def pi_permission_errors(claude: dict, pi: dict) -> list[str]:
    """Rule-by-rule parity between the Claude settings template and the Pi permission config."""
    sys.path.insert(0, str(ROOT))
    from tooling.generate.registry_sync import PATH_RULES

    errors: list[str] = []
    permission = pi.get("permission", {})
    rules = claude["permissions"]
    bash = permission.get("bash", {})
    if pi.get("yoloMode") is not False:
        errors.append("pi permission: yoloMode must be false")
    if list(bash)[:1] != ["*"] or bash.get("*") != "allow":
        errors.append("pi permission: bash must start with the allow-all rule")
    shell_ask = shell_patterns(rules["ask"])
    shell_deny = shell_patterns(rules["deny"])
    pi_ask = {pattern for pattern, value in bash.items() if value == "ask"}
    pi_deny = {pattern for pattern, value in bash.items() if value == "deny"}
    # A pattern that Claude denies and also asks resolves to deny, because Claude evaluates deny first.
    if pi_ask != shell_ask - shell_deny:
        errors.append(
            f"pi permission: bash ask rules differ from Claude: {sorted(pi_ask ^ (shell_ask - shell_deny))[:3]}"
        )
    if pi_deny != shell_deny:
        errors.append(f"pi permission: bash deny rules differ from Claude: {sorted(pi_deny ^ shell_deny)[:3]}")
    keys = list(bash)
    ask_positions = [index for index, key in enumerate(keys) if bash[key] == "ask"]
    deny_positions = [index for index, key in enumerate(keys) if bash[key] == "deny"]
    if ask_positions and deny_positions and min(deny_positions) < max(ask_positions):
        errors.append("pi permission: every bash deny rule must come after every ask rule (the last match wins)")
    if permission.get("path") != PATH_RULES:
        errors.append("pi permission: path rules must equal PATH_RULES")
    for tool in ("read", "write", "edit", "find", "grep", "ls"):
        if permission.get(tool) != "allow":
            errors.append(f"pi permission: {tool} must be allowed (path rules and the guard protect secrets)")
    mcp_keys = [key for key in permission if key.startswith("mcp__")]
    if mcp_keys[:1] != ["mcp__*"] or permission.get("mcp__*") != "ask":
        errors.append("pi permission: the broad mcp__* ask rule must come first")
    for label in ("allow", "ask", "deny"):
        claude_tools = {rule for rule in rules[label] if rule.startswith("mcp__")}
        pi_tools = {key for key in mcp_keys if key != "mcp__*" and permission[key] == label}
        if claude_tools != pi_tools:
            errors.append(f"pi permission: MCP {label} rules differ from Claude: {sorted(claude_tools ^ pi_tools)[:3]}")
    return errors


def main() -> int:
    skills = json.loads((ROOT / "skills/registry.yaml").read_text())["skills"]
    errors: list[str] = []
    runtimes = (("claude", "references/kernel.template.md", "skills"), ("pi", "pi/kernel.md", "pi/skills"))
    for runtime, kernel, directory in runtimes:
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
    claude_settings = json.loads((ROOT / "claude/configs/settings.template.json").read_text())
    pi_config = json.loads((ROOT / "pi/configs/permission.json").read_text())
    errors.extend(pi_permission_errors(claude_settings, pi_config))
    mutations = {
        "a bash deny rule turned into allow": lambda config: config["permission"]["bash"].update({"git pull": "allow"}),
        "a bash deny rule moved before the asks": lambda config: config["permission"].update(
            {"bash": {"*": "allow", "git push": "deny", **config["permission"]["bash"]}}
        ),
        "a path rule removed": lambda config: config["permission"]["path"].pop("*.pem"),
        "the mcp ask fallback removed": lambda config: config["permission"].pop("mcp__*"),
        "yolo mode enabled": lambda config: config.update({"yoloMode": True}),
        "an MCP allow turned into deny": lambda config: config["permission"].update(
            {"mcp__codegraph__codegraph_explore": "deny"}
        ),
    }
    for label, mutate in mutations.items():
        mutated = json.loads(json.dumps(pi_config))
        mutate(mutated)
        if not pi_permission_errors(claude_settings, mutated):
            errors.append(f"pi permission parity regression did not detect {label}")
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
