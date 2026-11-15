#!/usr/bin/env python3
"""Check shared instruction contracts; these scenarios do not simulate live agent behavior."""

from __future__ import annotations

import json
import re
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
    "opencode": "never allows `edit` or `subagent`",
}


def shell_patterns(rules: list[str]) -> set[str]:
    """The shell patterns inside a Claude Code rule list's `Bash(...)` entries."""
    return {rule.removeprefix("Bash(").removesuffix(")") for rule in rules if rule.startswith("Bash(")}


def mcp_action_name(rule: str) -> str:
    """`mcp__<server>__<tool>` as OpenCode names the action: `<server>_<tool>` with characters outside letters, digits, `_` and `-` as `_`."""
    server, _, tool = rule.removeprefix("mcp__").partition("__")
    return f"{re.sub(r'[^A-Za-z0-9_-]', '_', server)}_{re.sub(r'[^A-Za-z0-9_-]', '_', tool)}"


def opencode_permission_errors(claude: dict, template: dict) -> list[str]:
    """Rule-by-rule parity between the Claude settings template and the OpenCode permissions list."""
    sys.path.insert(0, str(ROOT))
    from tooling.generate.registry_sync import (
        DENY_READ_GLOBS,
        PATH_RULES,
        OPENCODE_APPROVAL_STORE_GLOB,
        OPENCODE_CODEX_ASKS,
        OPENCODE_RUN_STATE_GLOBS,
    )

    errors: list[str] = []
    rules = template.get("permissions")
    if not isinstance(rules, list) or not all(isinstance(rule, dict) for rule in rules):
        return ["opencode permission: expected a permissions list of {action, resource, effect}"]
    claude_rules = claude["permissions"]

    def pairs(action: str, effect: str) -> list[str]:
        return [r["resource"] for r in rules if r.get("action") == action and r.get("effect") == effect]

    if rules[:1] != [{"action": "*_*", "resource": "*", "effect": "ask"}]:
        errors.append("opencode permission: the `*_*` ask fallback for unclassified MCP actions must come first")
    if {"action": "external_directory", "resource": "*", "effect": "allow"} not in rules:
        errors.append("opencode permission: external_directory must be allowed after the `*_*` fallback")
    shell_ask = shell_patterns(claude_rules["ask"])
    shell_deny = shell_patterns(claude_rules["deny"])
    oc_ask, oc_deny = set(pairs("shell", "ask")) - set(OPENCODE_CODEX_ASKS), set(pairs("shell", "deny"))
    # A pattern that Claude denies and also asks resolves to deny, because Claude evaluates deny first.
    if oc_ask != shell_ask - shell_deny:
        errors.append(
            f"opencode permission: shell ask rules differ from Claude: {sorted(oc_ask ^ (shell_ask - shell_deny))[:3]}"
        )
    if oc_deny != shell_deny:
        errors.append(f"opencode permission: shell deny rules differ from Claude: {sorted(oc_deny ^ shell_deny)[:3]}")
    shell_positions = [(i, r["effect"]) for i, r in enumerate(rules) if r.get("action") == "shell"]
    ask_at = [i for i, effect in shell_positions if effect == "ask"]
    deny_at = [i for i, effect in shell_positions if effect == "deny"]
    if ask_at and deny_at and min(deny_at) < max(ask_at):
        errors.append(
            "opencode permission: every shell deny rule must come after every shell ask rule (last match wins)"
        )
    for action in ("read", "edit"):
        prefix = "Read(" if action == "read" else "Edit("
        wanted = {
            rule.removeprefix(prefix).removesuffix(")") for rule in claude_rules["deny"] if rule.startswith(prefix)
        }
        if wanted != set(DENY_READ_GLOBS):
            errors.append(f"opencode permission: Claude {action} deny globs differ from DENY_READ_GLOBS")
        have = [(r["resource"], r["effect"]) for r in rules if r.get("action") == action]
        expected = [(pattern, effect) for pattern, effect in PATH_RULES.items() if pattern != "*"]
        if action == "edit":
            expected += [(glob, "deny") for glob in OPENCODE_RUN_STATE_GLOBS]
            expected.append((OPENCODE_APPROVAL_STORE_GLOB, "deny"))
        if have != expected:
            errors.append(
                f"opencode permission: {action} path rules differ from PATH_RULES: {have[:2]} vs {expected[:2]}"
            )
    last_protection = max((i for i, r in enumerate(rules) if r.get("action") in {"shell", "read", "edit"}), default=-1)
    last_mcp = max((i for i, r in enumerate(rules) if r.get("action") not in {"shell", "read", "edit"}), default=-1)
    if last_mcp > last_protection:
        errors.append("opencode permission: the shell and path protections must come last")
    for label in ("allow", "ask", "deny"):
        claude_tools = {mcp_action_name(rule) for rule in claude_rules[label] if rule.startswith("mcp__")}
        oc_tools = {
            r["action"]
            for r in rules[1:]
            if r.get("effect") == label and r["action"] not in {"shell", "read", "edit", "external_directory", "*_*"}
        }
        if claude_tools != oc_tools:
            errors.append(
                f"opencode permission: MCP {label} rules differ from Claude: {sorted(claude_tools ^ oc_tools)[:3]}"
            )
    return errors


def main() -> int:
    skills = json.loads((ROOT / "skills/registry.yaml").read_text())["skills"]
    errors: list[str] = []
    runtimes = (
        ("claude", "references/kernel.template.md", "skills"),
        ("opencode", "opencode/kernel.md", "opencode/skills"),
    )
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
    template = json.loads((ROOT / "opencode/configs/opencode.template.json").read_text())
    errors.extend(opencode_permission_errors(claude_settings, template))

    def drop_first(config, action, effect):
        for index, rule in enumerate(config["permissions"]):
            if rule["action"] == action and rule["effect"] == effect:
                del config["permissions"][index]
                return

    mutations = {
        "a shell deny rule turned into allow": lambda config: [
            rule.update(effect="allow") for rule in config["permissions"] if rule["resource"] == "git pull"
        ],
        "a shell deny rule moved before the asks": lambda config: config["permissions"].insert(
            1, {"action": "shell", "resource": "git push", "effect": "deny"}
        ),
        "a secret read deny removed": lambda config: drop_first(config, "read", "deny"),
        "the unclassified MCP fallback removed": lambda config: config["permissions"].pop(0),
        "an MCP allow turned into deny": lambda config: [
            rule.update(effect="deny")
            for rule in config["permissions"]
            if rule["action"] == "codegraph_codegraph_explore"
        ],
        "an MCP rule moved after the protections": lambda config: config["permissions"].append(
            {"action": "codegraph_codegraph_explore", "resource": "*", "effect": "allow"}
        ),
        "the external_directory allow removed": lambda config: drop_first(config, "external_directory", "allow"),
    }
    for label, mutate in mutations.items():
        mutated = json.loads(json.dumps(template))
        mutate(mutated)
        if not opencode_permission_errors(claude_settings, mutated):
            errors.append(f"opencode permission parity regression did not detect {label}")
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
    print("Runtime instruction parity checks passed (Claude Code and OpenCode; live behavior unverified).")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
