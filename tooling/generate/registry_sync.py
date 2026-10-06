#!/usr/bin/env python3
"""Render Claude Code delivery assets from b-agentic's canonical sources."""

from __future__ import annotations

import argparse
import json
import re
import sys
import textwrap
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[2]
SKILL_REGISTRY_PATH = ROOT / "skills" / "registry.yaml"
KERNEL_TEMPLATE_PATH = ROOT / "references" / "kernel.template.md"
MCP_OPERATIONS_PATH = ROOT / "references" / "mcp_operations.yaml"
CAPABILITIES_PATH = ROOT / "references" / "capabilities.yaml"
CLAUDE_DIR = ROOT / "claude"
CLAUDE_AGENTS_DIR = CLAUDE_DIR / "agents"
CLAUDE_CONFIGS_DIR = CLAUDE_DIR / "configs"
SETTINGS_TEMPLATE_PATH = CLAUDE_CONFIGS_DIR / "settings.template.json"
SNAPSHOT_CLI_PATH = CLAUDE_DIR / "bin" / "b-candidate-snapshot.mjs"

README_SKILLS_START = "<!-- generated:skills-table:start -->"
README_SKILLS_END = "<!-- generated:skills-table:end -->"
MCP_OPERATIONS_START = "<!-- generated:mcp-operations:start -->"
MCP_OPERATIONS_END = "<!-- generated:mcp-operations:end -->"
KERNEL_ROUTING_START = "<!-- generated:kernel-routing:start -->"
KERNEL_ROUTING_END = "<!-- generated:kernel-routing:end -->"
KERNEL_DELEGATION_START = "<!-- generated:delegation:start -->"
KERNEL_DELEGATION_END = "<!-- generated:delegation:end -->"

EXECUTION_MODES = {"main", "subagent"}
PHASES = {"Decide", "Build", "Validate", "Ship"}
MANAGED_SUBAGENT_NAMES = {"b-planner", "b-researcher", "b-debugger", "b-auditor"}
AGENT_MODELS = {"opus", "sonnet", "haiku", "inherit"}
CAPABILITY_KINDS = {"mcp", "agent", "plugin"}
# Tools a read-only specialist must never receive, whatever the registry says.
EDITING_TOOLS = ("Edit", "Write", "NotebookEdit")
# Likely-secret path gate; the snapshot CLI mirrors everything after "*".
PATH_RULES = {
    "*": "allow",
    "*.env": "deny",
    "*.env.*": "deny",
    "*.env.example": "allow",
    "*.pem": "deny",
    "*credentials.*": "deny",
    "*secrets.*": "deny",
}
# Claude Code permission deny rules cannot carve out `.env.example`, so the
# settings layer denies only unambiguous secret files; the path-guard hook
# enforces PATH_RULES exactly.
DENY_READ_GLOBS = (
    "**/.env",
    "**/.env.local",
    "**/.env.*.local",
    "**/*.pem",
    "**/*credentials.*",
    "**/*secrets.*",
)
DENIED_COMMANDS = (
    "git push",
    "git pull",
    "git reset --hard",
    "git clean -f",
    "git branch -D",
    "rm -rf",
    "sudo",
    "doas",
    "docker system prune",
    "bash -s",
    "sh -s",
)
DENIED_BARE_COMMANDS = ("bash", "sh")
ALLOWED_TOOLS = ("Read", "Glob", "Grep", "Edit", "Write", "Bash", "Agent", "Task", "Skill", "AskUserQuestion")
ARGUMENT_HINT_MAX = 60
ARGUMENT_HINT_TOKEN = r"(?:<[A-Za-z0-9 ,/|._-]+>|\[[A-Za-z0-9 ,/|._-]+\])"
ARGUMENT_HINT_PATTERN = re.compile(rf"{ARGUMENT_HINT_TOKEN}(?: {ARGUMENT_HINT_TOKEN})*")
MCP_TOOL_PATTERN = re.compile(r"mcp__([a-z][a-z0-9_]*)__([A-Za-z0-9_.-]+)")


def load_json_subset_yaml(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text())
    except json.JSONDecodeError as exc:
        raise SystemExit(f"{path}: must use the JSON-compatible YAML subset: {exc}") from exc
    if not isinstance(value, dict):
        raise SystemExit(f"{path}: expected an object")
    return value


def ensure_string(value: object, label: str, errors: list[str]) -> str:
    if not isinstance(value, str) or not value:
        errors.append(f"{label}: expected non-empty string")
        return ""
    return value


def non_empty_string_list(value: object, label: str, errors: list[str]) -> None:
    if not isinstance(value, list) or not value or not all(isinstance(item, str) and item for item in value):
        errors.append(f"{label}: expected a non-empty string array")


def load_registry() -> dict[str, Any]:
    return load_json_subset_yaml(SKILL_REGISTRY_PATH)


def load_skills() -> list[dict[str, Any]]:
    skills = load_registry().get("skills")
    if not isinstance(skills, list):
        raise SystemExit(f"{SKILL_REGISTRY_PATH}: missing skills array")
    return skills


def load_agents() -> dict[str, dict[str, Any]]:
    agents = load_registry().get("agents")
    if not isinstance(agents, dict):
        raise SystemExit(f"{SKILL_REGISTRY_PATH}: missing agents object")
    return agents


def load_policy() -> dict[str, Any]:
    return load_json_subset_yaml(MCP_OPERATIONS_PATH)


def load_capabilities() -> dict[str, Any]:
    return load_json_subset_yaml(CAPABILITIES_PATH)


def mcp_tool_name(server: str, tool: str) -> str:
    """Claude Code's name for an MCP tool: mcp__<server>__<tool>."""
    return f"mcp__{server}__{tool}"


def validate_kernel_template(errors: list[str]) -> None:
    if not KERNEL_TEMPLATE_PATH.is_file():
        errors.append(f"{KERNEL_TEMPLATE_PATH}: missing Claude Code kernel template")
        return
    text = KERNEL_TEMPLATE_PATH.read_text()
    for marker in (
        "Claude Code Workflow Kernel",
        "<!-- b-agentic-managed -->",
        KERNEL_ROUTING_START,
        KERNEL_DELEGATION_START,
    ):
        if marker not in text:
            errors.append(f"{KERNEL_TEMPLATE_PATH}: missing {marker!r}")
    if len(text.encode()) > 12_800:
        errors.append(f"{KERNEL_TEMPLATE_PATH}: exceeds 12,800 byte kernel budget")
    if len(text.splitlines()) > 120:
        errors.append(f"{KERNEL_TEMPLATE_PATH}: exceeds 120 line kernel budget")


def validate_skills(skills: list[dict[str, Any]], agents: dict[str, dict[str, Any]]) -> list[str]:
    errors: list[str] = []
    validate_kernel_template(errors)
    prompt_dirs = {path.parent.name for path in (ROOT / "skills").glob("*/prompt.md")}
    names: list[str] = []
    delegated_agents: set[str] = set()

    for index, skill in enumerate(skills, start=1):
        label = f"skills[{index}]"
        if not isinstance(skill, dict):
            errors.append(f"{label}: expected object")
            continue
        name = ensure_string(skill.get("name"), f"{label}.name", errors)
        names.append(name)
        execution = skill.get("execution")
        if not isinstance(execution, dict):
            errors.append(f"{label}.execution: expected object")
        else:
            mode = ensure_string(execution.get("mode"), f"{label}.execution.mode", errors)
            if mode and mode not in EXECUTION_MODES:
                errors.append(f"{label}.execution.mode: expected {sorted(EXECUTION_MODES)}")
            agent = execution.get("agent")
            if mode == "subagent":
                agent_name = ensure_string(agent, f"{label}.execution.agent", errors)
                delegated_agents.add(agent_name)
                if agent_name and agent_name not in MANAGED_SUBAGENT_NAMES:
                    errors.append(f"{label}.execution.agent: unmanaged agent {agent_name!r}")
            elif agent is not None:
                errors.append(f"{label}.execution.agent: only subagent skills may name an agent")
        handoff = skill.get("handoff")
        if handoff is not None:
            if not isinstance(execution, dict) or execution.get("mode") != "subagent":
                errors.append(f"{label}.handoff: only subagent skills may define a handoff")
            non_empty_string_list(handoff, f"{label}.handoff", errors)
        phase = ensure_string(skill.get("phase"), f"{label}.phase", errors)
        if phase and phase not in PHASES:
            errors.append(f"{label}.phase: expected {sorted(PHASES)}")
        ensure_string(skill.get("use"), f"{label}.use", errors)
        hint = skill.get("argument_hint")
        if hint is not None:
            hint = ensure_string(hint, f"{label}.argument_hint", errors)
            if hint and (len(hint) > ARGUMENT_HINT_MAX or not ARGUMENT_HINT_PATTERN.fullmatch(hint)):
                errors.append(
                    f"{label}.argument_hint: expected <required> or [optional] text of at most {ARGUMENT_HINT_MAX} characters"
                )
        prompt = skill.get("prompt")
        if not isinstance(prompt, dict):
            errors.append(f"{label}.prompt: expected object")
        else:
            ensure_string(prompt.get("description"), f"{label}.prompt.description", errors)
            if set(prompt) != {"description"}:
                errors.append(f"{label}.prompt: only description is supported by native skill front matter")
        routing = skill.get("routing")
        if not isinstance(routing, dict):
            errors.append(f"{label}.routing: expected object")
        else:
            ensure_string(routing.get("intent"), f"{label}.routing.intent", errors)
            explicit = routing.get("explicit_request", False)
            if not isinstance(explicit, bool):
                errors.append(f"{label}.routing.explicit_request: expected boolean")
            triggers = routing.get("triggers")
            if explicit:
                if triggers is not None:
                    errors.append(f"{label}.routing.triggers: explicit-request skills must omit triggers")
            elif not isinstance(triggers, list) or not triggers:
                errors.append(f"{label}.routing.triggers: expected non-empty array")
            elif not all(isinstance(trigger, str) and trigger for trigger in triggers):
                errors.append(f"{label}.routing.triggers: expected non-empty strings")
        if name and not (ROOT / "skills" / name / "prompt.md").is_file():
            errors.append(f"skills/{name}/prompt.md: missing canonical prompt source")
        elif name and f"\n{DELEGATION_BOUNDARY_HEADING}" in (ROOT / "skills" / name / "prompt.md").read_text():
            errors.append(
                f"skills/{name}/prompt.md: '{DELEGATION_BOUNDARY_HEADING}' is generator-owned; remove it from the prompt"
            )

    if len(names) != len(set(names)):
        errors.append("skills/registry.yaml: duplicate skill names")
    missing = sorted(prompt_dirs - set(names))
    extra = sorted(set(names) - prompt_dirs)
    if missing or extra:
        errors.append(f"skills/registry.yaml: prompt directory mismatch (missing={missing}, extra={extra})")
    if set(agents) != MANAGED_SUBAGENT_NAMES:
        errors.append(f"skills/registry.yaml: agents must name {sorted(MANAGED_SUBAGENT_NAMES)}")
    for name, agent in agents.items():
        label = f"agents.{name}"
        if not isinstance(agent, dict):
            errors.append(f"{label}: expected object")
            continue
        ensure_string(agent.get("description"), f"{label}.description", errors)
        model = ensure_string(agent.get("model"), f"{label}.model", errors)
        if model and model not in AGENT_MODELS:
            errors.append(f"{label}.model: expected one of {sorted(AGENT_MODELS)}")
        allowed_fields = {"description", "model"}
        if "max_turns" in agent:
            allowed_fields.add("max_turns")
            turns = agent["max_turns"]
            if isinstance(turns, bool) or not isinstance(turns, int) or turns < 1:
                errors.append(f"{label}.max_turns: expected positive integer")
        if name == "b-researcher":
            allowed_fields.add("conditional_tools")
            non_empty_string_list(agent.get("conditional_tools"), f"{label}.conditional_tools", errors)
        if set(agent) != allowed_fields:
            errors.append(f"{label}: expected only {sorted(allowed_fields)}")
    if delegated_agents != MANAGED_SUBAGENT_NAMES:
        errors.append(f"skills/registry.yaml: delegated skills must use {sorted(MANAGED_SUBAGENT_NAMES)}")
    return errors


def validate_agent_tools(agents: dict[str, dict[str, Any]], policy: dict[str, Any]) -> list[str]:
    conditional = {
        mcp_tool_name(server, tool)
        for server, record in policy["servers"].items()
        for tool, classification in record["tools"].items()
        if classification == "conditional-read"
    }
    errors: list[str] = []
    for name, agent in agents.items():
        tools = agent.get("conditional_tools", [])
        if (
            not isinstance(tools, list)
            or not all(isinstance(tool, str) for tool in tools)
            or len(tools) != len(set(tools))
        ):
            errors.append(f"agents.{name}.conditional_tools: expected unique tool names")
            continue
        for tool in tools:
            if tool not in conditional:
                errors.append(f"agents.{name}.conditional_tools: {tool!r} is not a conditional-read tool")
    return errors


def validate_snapshot_cli() -> list[str]:
    """Keep the snapshot CLI, the path rules, and the manual fallback in step."""
    errors: list[str] = []
    label = SNAPSHOT_CLI_PATH.relative_to(ROOT)
    if not SNAPSHOT_CLI_PATH.is_file():
        return [f"{label}: missing managed snapshot CLI"]
    text = SNAPSHOT_CLI_PATH.read_text()
    if 'SNAPSHOT_SCHEMA = "b-candidate-snapshot/3"' not in text:
        errors.append(f"{label}: snapshot schema must stay b-candidate-snapshot/3")
    flags_block = re.search(r"SNAPSHOT_DIFF_FLAGS = \[(.*?)\];", text, re.S)
    flags = re.findall(r'"([^"]+)"', flags_block.group(1)) if flags_block else []
    if not flags:
        errors.append(f"{label}: SNAPSHOT_DIFF_FLAGS not found")
    review = (ROOT / "skills" / "b-review" / "prompt.md").read_text()
    for variant in (f"git diff {' '.join(flags)} --cached -- .", f"git diff {' '.join(flags)} -- ."):
        if flags and f"`{variant}`" not in review:
            errors.append(f"skills/b-review/prompt.md: manual fallback must contain `{variant}`")
    rules_block = re.search(r"PROTECTED_RULES[^=]*= \[(.*?)\n\];", text, re.S)
    rules = re.findall(r'\["([^"]+)", "(allow|deny)"\]', rules_block.group(1)) if rules_block else []
    policy_rules = [(pattern, action) for pattern, action in PATH_RULES.items() if pattern != "*"]
    if rules != policy_rules:
        errors.append(f"{label}: PROTECTED_RULES must match the generated path rules")
    return errors


def validate_policy(policy: dict[str, Any]) -> list[str]:
    errors: list[str] = []
    if policy.get("schema_version") != 1:
        errors.append(f"{MCP_OPERATIONS_PATH}: schema_version must be 1")
    if policy.get("format") != "json-subset-of-yaml":
        errors.append(f"{MCP_OPERATIONS_PATH}: format must be json-subset-of-yaml")
    classes = policy.get("classes")
    servers = policy.get("servers")
    if not isinstance(classes, dict) or not classes:
        errors.append(f"{MCP_OPERATIONS_PATH}: classes must be a non-empty object")
    if not isinstance(servers, dict) or not servers:
        errors.append(f"{MCP_OPERATIONS_PATH}: servers must be a non-empty object")
    if not isinstance(classes, dict) or not isinstance(servers, dict):
        return errors
    for name, meta in classes.items():
        if not isinstance(name, str) or not isinstance(meta, dict):
            errors.append(f"{MCP_OPERATIONS_PATH}: invalid class {name!r}")
            continue
        for field in ("policy", "native_permission", "notes"):
            ensure_string(meta.get(field), f"classes.{name}.{field}", errors)
        if meta.get("native_permission") not in {"allow", "ask", "deny"}:
            errors.append(f"classes.{name}.native_permission: expected allow, ask, or deny")
    seen_tools: set[str] = set()
    for server, record in servers.items():
        if not isinstance(server, str) or not re.fullmatch(r"[a-z][a-z0-9_]*", server):
            errors.append(f"servers.{server}: server name must be lowercase letters, digits, and underscores")
            continue
        tools = record.get("tools") if isinstance(record, dict) else None
        if not isinstance(tools, dict) or not tools:
            errors.append(f"servers.{server}.tools: expected non-empty object")
            continue
        if set(record) != {"tools"}:
            errors.append(f"servers.{server}: expected only a tools object")
        for tool, class_name in tools.items():
            if not re.fullmatch(r"[A-Za-z0-9_.-]+", str(tool)):
                errors.append(f"servers.{server}.tools.{tool}: invalid tool name")
                continue
            name = mcp_tool_name(server, str(tool))
            if name in seen_tools:
                errors.append(f"{MCP_OPERATIONS_PATH}: duplicate tool name {name!r}")
            seen_tools.add(name)
            if class_name not in classes:
                errors.append(f"servers.{server}.tools.{tool}: unknown class {class_name!r}")
    return errors


def validate_capabilities(contract: dict[str, Any], policy: dict[str, Any]) -> list[str]:
    errors: list[str] = []
    if contract.get("schema_version") != 1:
        errors.append(f"{CAPABILITIES_PATH}: schema_version must be 1")
    if contract.get("format") != "json-subset-of-yaml":
        errors.append(f"{CAPABILITIES_PATH}: format must be json-subset-of-yaml")
    capabilities = contract.get("capabilities")
    if not isinstance(capabilities, list) or not capabilities:
        return [*errors, f"{CAPABILITIES_PATH}: capabilities must be a non-empty array"]
    identifiers: set[str] = set()
    mcp_servers: set[str] = set()
    agent_names: set[str] = set()
    for index, capability in enumerate(capabilities, start=1):
        label = f"capabilities[{index}]"
        if not isinstance(capability, dict):
            errors.append(f"{label}: expected object")
            continue
        identifier = ensure_string(capability.get("id"), f"{label}.id", errors)
        if identifier in identifiers:
            errors.append(f"{label}.id: duplicate {identifier!r}")
        identifiers.add(identifier)
        kind = ensure_string(capability.get("kind"), f"{label}.kind", errors)
        if kind not in CAPABILITY_KINDS:
            errors.append(f"{label}.kind: expected one of {sorted(CAPABILITY_KINDS)}")
        for field in ("purpose", "owner", "trigger", "readiness", "fallback"):
            ensure_string(capability.get(field), f"{label}.{field}", errors)
        non_empty_string_list(capability.get("prerequisites"), f"{label}.prerequisites", errors)
        signal = capability.get("status_signal")
        if not isinstance(signal, dict) or signal.get("sensitive") is not False:
            errors.append(f"{label}.status_signal: must be a non-sensitive object")
        probe = capability.get("probe")
        if not isinstance(probe, dict) or probe.get("type") != kind:
            errors.append(f"{label}.probe.type: must match capability kind")
        state = capability.get("install_state")
        if not isinstance(state, dict) or set(state) != {"action", "state"}:
            errors.append(f"{label}.install_state: expected action and state")
        source = capability.get("source")
        if not isinstance(source, dict) or not source:
            errors.append(f"{label}.source: expected non-empty object")
        if kind == "mcp":
            mcp = capability.get("mcp")
            if not isinstance(mcp, dict):
                errors.append(f"{label}.mcp: expected object")
            else:
                server = ensure_string(mcp.get("server"), f"{label}.mcp.server", errors)
                mcp_servers.add(server)
                if isinstance(probe, dict) and probe.get("server") != server:
                    errors.append(f"{label}.probe.server: must match mcp.server")
        if kind == "agent":
            agent = capability.get("agent")
            names = agent.get("names") if isinstance(agent, dict) else None
            if not isinstance(names, list) or set(names) != MANAGED_SUBAGENT_NAMES:
                errors.append(f"{label}.agent.names: must name {sorted(MANAGED_SUBAGENT_NAMES)}")
            else:
                agent_names.update(names)
                source_dir = agent.get("source")
                if source_dir != str(CLAUDE_AGENTS_DIR.relative_to(ROOT)):
                    errors.append(f"{label}.agent.source: expected generated Claude Code agent directory")
        if kind == "plugin" and (
            not isinstance(probe, dict) or not isinstance(probe.get("plugin"), str) or not probe["plugin"]
        ):
            errors.append(f"{label}.probe.plugin: expected plugin identifier")
    policy_servers = set((policy.get("servers") or {}).keys())
    if mcp_servers != policy_servers:
        errors.append(f"{CAPABILITIES_PATH}: MCP server set differs from policy")
    if agent_names != MANAGED_SUBAGENT_NAMES:
        errors.append(f"{CAPABILITIES_PATH}: missing managed specialist agents")
    return errors


def render_readme_skills_table(skills: list[dict[str, Any]]) -> str:
    rows = ["| Skill | Phase | Use |", "|---|---|---|"]
    rows.extend(f"| `{skill['name']}` | {skill['phase']} | {skill['use']} |" for skill in skills)
    return "\n".join(rows)


def render_mcp_operations_table(policy: dict[str, Any]) -> str:
    rows = ["| Class | Policy | Scope |", "|---|---|---|"]
    for name, meta in policy["classes"].items():
        rows.append(f"| `{name}` | {meta['policy']} | {meta['notes']} |")
    rows.append("")
    rows.append(
        "Unclassified MCP tools keep Claude Code's approval prompt. Specialists call only the read-only tools their profile lists."
    )
    return "\n".join(rows)


def render_delegation(skills: list[dict[str, Any]]) -> str:
    delegated = [skill for skill in skills if skill["execution"]["mode"] == "subagent"]
    lines = [
        "- Delegated skills run only in their named `Agent` subagent type with a bounded task naming the exact skill. Never do their work with main-session tools, even for a quick lookup or when a tool description invites it; if the subagent is unavailable, report the gap and ask. A missing or editing-capable agent profile, or `general-purpose` fallback, counts as unavailable. The child reads its `SKILL.md` and returns that skill's own Output format; main evaluates it before any user-facing or worktree action:",
    ]
    lines.extend(f"  - `{skill['name']}` -> `{skill['execution']['agent']}`." for skill in delegated)
    lines.append("- All other skills run in the main session.")
    return "\n".join(lines)


DELEGATION_BOUNDARY_HEADING = "## Delegation boundary"


def render_delegation_boundary(skill: dict[str, Any]) -> str:
    name = skill["name"]
    agent = skill["execution"]["agent"]
    editing = ", ".join(f"`{tool}`" for tool in EDITING_TOOLS)
    lines = [
        DELEGATION_BOUNDARY_HEADING,
        "",
        f"`{name}` runs only in the `{agent}` subagent.",
        "",
        f"- Main session: reading this file prepares the handoff; it never authorizes running the steps below yourself. Gather the parent-owned evidence and confirm the effective `{agent}.md` (project `.claude/agents/` over `~/.claude/agents/`) is readable and its parsed frontmatter `tools` value, normalized to a list (comma-separated scalar or YAML sequence), is explicit, non-empty, and contains none of {editing} (a missing, blank, or null `tools` grants every tool), then call the `Agent` tool with `subagent_type` `{agent}` and a bounded task naming `{name}`. Do not do this skill's work with your own tools, even for a quick, small, or single-lookup request. If the subagent is unavailable or fails, or its result notes an unknown agent type or `general-purpose` fallback (discard that result), report the gap and ask the user; never fall back to self-execution. Evaluate the returned result before any user-facing or worktree action.",
        f"- `{agent}` child: execute the steps below read-only, return this skill's Output format to the main session, and do not delegate again.",
    ]
    handoff = skill.get("handoff", [])
    if handoff:
        lines.extend(
            [
                "",
                "Parent-owned evidence to gather and pass to the child (or state what is unavailable):",
                "",
                *[f"- {item}" for item in handoff],
            ]
        )
    lines.extend(["", "User arguments for the bounded task: $ARGUMENTS"])
    return "\n".join(lines)


def render_routing(skills: list[dict[str, Any]]) -> str:
    lines = []
    for skill in skills:
        suffix = " only on explicit user request" if skill["routing"].get("explicit_request") else ""
        lines.append(f"- {skill['routing']['intent']} -> `{skill['name']}`{suffix}.")
    return "\n".join(lines)


def fold_yaml(key: str, value: str) -> list[str]:
    wrapper = textwrap.TextWrapper(width=74, initial_indent="  ", subsequent_indent="  ", break_long_words=False)
    return [f"{key}: >", *wrapper.fill(value).splitlines()]


def render_skill_file(skill: dict[str, Any]) -> str:
    name = skill["name"]
    description = skill["prompt"]["description"]
    triggers = skill["routing"].get("triggers")
    if triggers:
        description += f" Routing signals: {', '.join(triggers)}."
    body = (ROOT / "skills" / name / "prompt.md").read_text().rstrip()
    body = body.replace("{{skill_support_path}}", "<skill-dir>")
    execution = skill["execution"]
    if execution["mode"] == "subagent":
        head, sep, rest = body.partition("\n## ")
        if not sep:
            raise SystemExit(f"skills/{name}/prompt.md: expected a '## ' section to place the delegation boundary")
        body = f"{head}\n{render_delegation_boundary(skill)}\n\n## {rest}"
        description += (
            f" Delegated: runs only in the `{execution['agent']}` subagent; the main session never executes it itself."
        )
    lines = ["---", f"name: {name}"]
    lines.extend(fold_yaml("description", description))
    if skill.get("argument_hint"):
        lines.append(f"argument-hint: {json.dumps(skill['argument_hint'], ensure_ascii=False)}")
    if skill["routing"].get("explicit_request"):
        # Explicit-request skills stay out of Claude's automatic skill matching; /<name> still loads them.
        lines.append("disable-model-invocation: true")
    lines.extend(
        [
            "metadata:",
            f"  phase: {skill['phase']}",
            f"  execution_mode: {execution['mode']}",
        ]
    )
    if execution["mode"] == "subagent":
        lines.append(f"  agent: {execution['agent']}")
    lines.extend(
        [
            "---",
            "",
            f"<!-- Generated from skills/registry.yaml and skills/{name}/prompt.md. Edit those sources, not this file. -->",
            "",
            body,
            "",
        ]
    )
    return "\n".join(lines)


TURN_BUDGET_NOTICE = (
    "If the harness warns about your turn budget, make no further tool calls: return the skill's Output format "
    "now with partial findings, explicit gaps, and the narrowest next step for the main session."
)


def read_only_mcp_tools(policy: dict[str, Any]) -> list[str]:
    return [
        mcp_tool_name(server, tool)
        for server, record in policy["servers"].items()
        for tool, class_name in record["tools"].items()
        if class_name == "read-only"
    ]


def agent_tool_list(agent: dict[str, Any], policy: dict[str, Any]) -> list[str]:
    return ["Read", "Grep", "Glob", "Bash", *read_only_mcp_tools(policy), *agent.get("conditional_tools", [])]


def render_agent_file(
    name: str, agent: dict[str, Any], skills: list[dict[str, Any]], policy: dict[str, Any] | None = None
) -> str:
    policy = policy if policy is not None else load_policy()
    bound_skills = [
        skill["name"]
        for skill in skills
        if skill["execution"]["mode"] == "subagent" and skill["execution"]["agent"] == name
    ]
    skill_list = " or ".join(f"`{skill}`" for skill in bound_skills)
    return "\n".join(
        [
            "---",
            f"name: {name}",
            f"description: {json.dumps(agent['description'])}",
            f"tools: {', '.join(agent_tool_list(agent, policy))}",
            f"model: {agent['model']}",
            *([f"maxTurns: {agent['max_turns']}"] if "max_turns" in agent else []),
            "---",
            "",
            f"You are the b-agentic `{name}` subagent. The main session delegates only {skill_list} to you and has already selected the exact skill; do not route again or launch a nested subagent.",
            "",
            "Read and execute the named skill from the installed `~/.claude/skills/<name>/SKILL.md` for the supplied bounded task. Return that skill's own Output format; do not substitute a profile-specific template. The skill's Delegation boundary directs the main session to delegate; you are the named child, so execute its steps.",
            "",
            "Remain read-only. Do not edit, write, commit, stage, run generators or fixers, or ask the user questions. Do not execute external/shared mutation, local upload, lifecycle, or authentication actions; report the required operation to the main session. A returned result is not authority to change files, commit, push, or report task completion. If a required tool is absent, tell the main session rather than bypassing the allowlist.",
            "",
            TURN_BUDGET_NOTICE,
            "",
            "<!-- Managed by b-agentic. Generated from skills/registry.yaml. Do not edit this file. -->",
            "",
        ]
    )


HOOK_DIR = '"$HOME/.claude/b-agentic/hooks'


def hook_command(script: str) -> str:
    return f'node {HOOK_DIR}/{script}"'


def render_hooks() -> dict[str, Any]:
    """Hook entries merged into the user's settings.json, keyed by exact command."""
    return {
        "PreToolUse": [
            {
                "matcher": "Read|Edit|Write|NotebookEdit|Grep|Glob",
                "hooks": [{"type": "command", "command": hook_command("b-path-guard.mjs")}],
            },
            {
                "matcher": "Bash",
                "hooks": [{"type": "command", "command": hook_command("b-codex-guard.mjs")}],
            },
        ],
        "PostToolUse": [
            {
                "matcher": "Edit|Write|NotebookEdit|Bash",
                "hooks": [{"type": "command", "command": hook_command("b-verify-gate.mjs")}],
            }
        ],
        "Stop": [{"hooks": [{"type": "command", "command": hook_command("b-verify-gate.mjs")}]}],
    }


def render_settings(policy: dict[str, Any]) -> dict[str, Any]:
    return {**render_permissions(policy), "hooks": render_hooks()}


def render_permissions(policy: dict[str, Any]) -> dict[str, Any]:
    """Permission rules merged into the user's Claude Code settings.json."""
    allow = list(ALLOWED_TOOLS)
    ask: list[str] = []
    deny: list[str] = []
    for command in DENIED_COMMANDS:
        for prefix in ("", "rtk "):
            deny.extend([f"Bash({prefix}{command})", f"Bash({prefix}{command} *)"])
    deny.extend(f"Bash({command})" for command in DENIED_BARE_COMMANDS)
    for tool in ("Read", "Edit", "Write"):
        deny.extend(f"{tool}({glob})" for glob in DENY_READ_GLOBS)
    for server, record in policy["servers"].items():
        for tool, class_name in record["tools"].items():
            permission = policy["classes"][class_name]["native_permission"]
            name = mcp_tool_name(server, tool)
            if permission == "allow":
                allow.append(name)
            elif permission == "ask":
                ask.append(name)
            else:
                deny.append(name)
    return {"permissions": {"allow": allow, "ask": ask, "deny": deny}}


def replace_block(text: str, start: str, end: str, body: str) -> str:
    try:
        body_start = text.index(start) + len(start)
        body_end = text.index(end, body_start)
    except ValueError as exc:
        raise SystemExit(f"missing generated block markers: {start} / {end}") from exc
    return text[:body_start] + "\n" + body.rstrip() + "\n" + text[body_end:]


def render_outputs(
    skills: list[dict[str, Any]], agents: dict[str, dict[str, Any]], policy: dict[str, Any]
) -> dict[Path, str]:
    readme = ROOT / "README.md"
    kernel = KERNEL_TEMPLATE_PATH.read_text()
    kernel = replace_block(kernel, KERNEL_ROUTING_START, KERNEL_ROUTING_END, render_routing(skills))
    kernel = replace_block(kernel, KERNEL_DELEGATION_START, KERNEL_DELEGATION_END, render_delegation(skills))
    kernel = replace_block(kernel, MCP_OPERATIONS_START, MCP_OPERATIONS_END, render_mcp_operations_table(policy))
    outputs = {
        readme: replace_block(
            readme.read_text(), README_SKILLS_START, README_SKILLS_END, render_readme_skills_table(skills)
        ),
        KERNEL_TEMPLATE_PATH: kernel,
        SETTINGS_TEMPLATE_PATH: json.dumps(render_settings(policy), indent=2) + "\n",
    }
    for skill in skills:
        outputs[ROOT / "skills" / skill["name"] / "SKILL.md"] = render_skill_file(skill)
    for name, agent in agents.items():
        outputs[CLAUDE_AGENTS_DIR / f"{name}.md"] = render_agent_file(name, agent, skills, policy)
    return outputs


def validate_regressions(
    skills: list[dict[str, Any]],
    agents: dict[str, dict[str, Any]],
    capabilities: dict[str, Any],
    policy: dict[str, Any],
) -> list[str]:
    errors: list[str] = []
    invalid_skill = json.loads(json.dumps(skills))
    invalid_skill[0]["execution"] = {"mode": "invalid"}
    if not validate_skills(invalid_skill, agents):
        errors.append("skill regression: invalid execution mode must fail")
    invalid_handoff = json.loads(json.dumps(skills))
    next(skill for skill in invalid_handoff if skill["name"] == "b-design")["handoff"] = ["parent evidence"]
    if not any("handoff: only subagent skills" in error for error in validate_skills(invalid_handoff, agents)):
        errors.append("skill regression: main skill cannot declare subagent handoff")
    invalid_handoff = json.loads(json.dumps(skills))
    next(skill for skill in invalid_handoff if skill["execution"]["mode"] == "subagent")["handoff"] = []
    if not any(
        "handoff: expected a non-empty string array" in error for error in validate_skills(invalid_handoff, agents)
    ):
        errors.append("skill regression: empty handoff must fail")
    for skill in skills:
        if skill.get("handoff"):
            rendered = render_skill_file(skill)
            if any(item not in rendered for item in skill["handoff"]):
                errors.append(f"skill regression: {skill['name']} handoff missing from generated skill")
    for skill in skills:
        explicit = bool(skill["routing"].get("explicit_request"))
        flagged = "\ndisable-model-invocation: true\n" in render_skill_file(skill)
        if flagged != explicit:
            errors.append(f"skill regression: {skill['name']} disable-model-invocation must match explicit_request")
        hint = skill.get("argument_hint")
        if bool(hint) != (f"\nargument-hint: {json.dumps(hint, ensure_ascii=False)}\n" in render_skill_file(skill)):
            errors.append(f"skill regression: {skill['name']} argument-hint must match the registry")
    for skill in skills:
        rendered = render_skill_file(skill)
        has_boundary = f"\n{DELEGATION_BOUNDARY_HEADING}\n" in rendered
        if skill["execution"]["mode"] == "subagent":
            agent_name = skill["execution"]["agent"]
            required = (
                f"`{skill['name']}` runs only in the `{agent_name}` subagent.",
                "even for a quick, small, or single-lookup request",
                "never fall back to self-execution",
                "$ARGUMENTS",
            )
            if not has_boundary or any(clause not in rendered for clause in required):
                errors.append(f"delegation regression: {skill['name']} SKILL.md must carry the strict boundary")
        elif has_boundary:
            errors.append(f"delegation regression: main skill {skill['name']} must not carry a delegation boundary")
    delegation = render_delegation(skills)
    if "even for a quick lookup" not in delegation or "report the gap and ask" not in delegation:
        errors.append("delegation regression: kernel delegation block must forbid main-session execution")

    def hint_errors(hint: str) -> list[str]:
        candidate = json.loads(json.dumps(skills))
        candidate[0]["argument_hint"] = hint
        return [error for error in validate_skills(candidate, agents) if "argument_hint" in error]

    def bracketed(length: int) -> str:
        return "[" + "x" * (length - 2) + "]"

    for bad in ("<required]", "[optional>", "", "no brackets", bracketed(ARGUMENT_HINT_MAX + 1)):
        if not hint_errors(bad):
            errors.append(f"skill regression: invalid argument_hint {bad!r} must fail")
    for good in ("<required>", "[optional]", "<a> [b]", bracketed(ARGUMENT_HINT_MAX)):
        if hint_errors(good):
            errors.append(f"skill regression: valid argument_hint {good!r} must pass")
    invalid_agents = json.loads(json.dumps(agents))
    invalid_agents["b-planner"].pop("model")
    if not validate_skills(skills, invalid_agents):
        errors.append("agent regression: missing model must fail")
    invalid_agents = json.loads(json.dumps(agents))
    invalid_agents["b-planner"]["model"] = "gpt-9"
    if not validate_skills(skills, invalid_agents):
        errors.append("agent regression: unknown model alias must fail")
    for name, agent in agents.items():
        rendered = render_agent_file(name, agent, skills, policy)
        if TURN_BUDGET_NOTICE not in rendered:
            errors.append(f"agent regression: {name} profile must carry the turn-budget wrap-up notice")
        tools = agent_tool_list(agent, policy)
        if any(tool in tools for tool in EDITING_TOOLS) or "Agent" in tools or "Task" in tools:
            errors.append(f"agent regression: {name} profile must stay read-only and non-delegating")
        if any(tool.startswith("mcp__notion__") for tool in tools):
            errors.append(f"agent regression: {name} must not receive private Notion workspace tools")
    for bad_turns in (0, -1, True, "25"):
        invalid_turns = json.loads(json.dumps(agents))
        invalid_turns["b-researcher"]["max_turns"] = bad_turns
        if not validate_skills(skills, invalid_turns):
            errors.append(f"agent regression: invalid max_turns {bad_turns!r} must fail")
    invalid_capabilities = json.loads(json.dumps(capabilities))
    invalid_capabilities["capabilities"][0].pop("status_signal", None)
    if not validate_capabilities(invalid_capabilities, policy):
        errors.append("capability regression: missing status signal must fail")
    invalid_agent_tools = json.loads(json.dumps(agents))
    invalid_agent_tools["b-researcher"]["conditional_tools"].append("mcp__playwright__browser_click")
    if not validate_agent_tools(invalid_agent_tools, policy):
        errors.append("agent regression: mutating conditional tool must fail")
    errors.extend(validate_snapshot_cli())
    # Playwright's browser_find accepts a `filename` that writes results to disk, so it must
    # never be classed read-only (which auto-exposes it to every specialist profile).
    if policy["servers"]["playwright"]["tools"]["browser_find"] == "read-only":
        errors.append("MCP policy regression: file-writing browser_find must not be read-only")
    for agent_name, agent in agents.items():
        if "mcp__playwright__browser_find" in agent.get("conditional_tools", []):
            errors.append(f"agents.{agent_name}: file-writing browser_find must not be a specialist tool")
    invalid_policy = json.loads(json.dumps(policy))
    first_server = next(iter(invalid_policy["servers"].values()))
    first_server["tools"]["bad"] = "missing"
    if not validate_policy(invalid_policy):
        errors.append("MCP policy regression: unknown class must fail")
    invalid_policy = json.loads(json.dumps(policy))
    next(iter(invalid_policy["servers"].values()))["exposure"] = "eager"
    if not validate_policy(invalid_policy):
        errors.append("MCP policy regression: retired exposure field must fail")
    return errors


def sync_outputs(check: bool) -> int:
    skills = load_skills()
    agents = load_agents()
    policy = load_policy()
    capabilities = load_capabilities()
    errors = [
        *validate_skills(skills, agents),
        *validate_policy(policy),
        *validate_agent_tools(agents, policy),
        *validate_capabilities(capabilities, policy),
        *validate_snapshot_cli(),
    ]
    if errors:
        print("\n".join(errors), file=sys.stderr)
        return 1
    outputs = render_outputs(skills, agents, policy)
    stale = [path for path, content in outputs.items() if not path.exists() or path.read_text() != content]
    if check and stale:
        print("\n".join(f"generated output out of date: {path.relative_to(ROOT)}" for path in stale), file=sys.stderr)
        return 1
    if not check:
        for path in stale:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(outputs[path])
        print("Generated Claude Code delivery assets refreshed.")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description="Render Claude Code assets from canonical b-agentic sources.")
    parser.add_argument("--check", action="store_true", help="fail when generated outputs are stale")
    parser.add_argument("--self-test", action="store_true", help="verify invalid canonical contracts fail validation")
    args = parser.parse_args()
    if args.self_test:
        errors = validate_regressions(load_skills(), load_agents(), load_capabilities(), load_policy())
        if errors:
            print("\n".join(errors), file=sys.stderr)
            return 1
        print("Skill, capability, and MCP policy regression checks passed.")
    return sync_outputs(args.check)


if __name__ == "__main__":
    raise SystemExit(main())
