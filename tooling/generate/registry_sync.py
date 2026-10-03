#!/usr/bin/env python3
"""Render native Pi delivery assets from b-agentic's canonical sources."""

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
PI_CONFIGS_DIR = ROOT / "pi" / "configs"
PI_PROMPTS_DIR = ROOT / "pi" / "prompts"
PI_AGENTS_DIR = ROOT / "pi" / "agents"

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
MCP_EXPOSURES = {"direct", "search"}
MANAGED_SUBAGENT_NAMES = {"b-planner", "b-researcher", "b-debugger", "b-reviewer"}
CAPABILITY_KINDS = {"mcp", "agent"}
# Native tools registered by managed extensions; only the named agents may list them.
EXTENSION_TOOLS = {"b_candidate_snapshot": "b-candidate-snapshot.ts"}
EXTENSION_TOOL_AGENTS = {"b-reviewer"}
# Likely-secret path gate; the snapshot extension mirrors everything after "*".
PATH_RULES = {
    "*": "allow",
    "*.env": "deny",
    "*.env.*": "deny",
    "*.env.example": "allow",
    "*.pem": "deny",
    "*credentials.*": "deny",
    "*secrets.*": "deny",
}
PI_EXTENSIONS_DIR = ROOT / "pi" / "extensions"
ARGUMENT_HINT_MAX = 60
ARGUMENT_HINT_TOKEN = r"(?:<[A-Za-z0-9 ,/|._-]+>|\[[A-Za-z0-9 ,/|._-]+\])"
ARGUMENT_HINT_PATTERN = re.compile(rf"{ARGUMENT_HINT_TOKEN}(?: {ARGUMENT_HINT_TOKEN})*")


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


def validate_kernel_template(errors: list[str]) -> None:
    if not KERNEL_TEMPLATE_PATH.is_file():
        errors.append(f"{KERNEL_TEMPLATE_PATH}: missing Pi kernel template")
        return
    text = KERNEL_TEMPLATE_PATH.read_text()
    for marker in (
        "Pi Workflow Kernel",
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
        ensure_string(agent.get("model"), f"{label}.model", errors)
        allowed_fields = {"description", "model"}
        if "max_turns" in agent:
            allowed_fields.add("max_turns")
            turns = agent["max_turns"]
            if isinstance(turns, bool) or not isinstance(turns, int) or turns < 1:
                errors.append(f"{label}.max_turns: expected positive integer")
        if name == "b-researcher":
            allowed_fields.add("conditional_tools")
            non_empty_string_list(agent.get("conditional_tools"), f"{label}.conditional_tools", errors)
        if name in EXTENSION_TOOL_AGENTS:
            allowed_fields.add("extension_tools")
            non_empty_string_list(agent.get("extension_tools"), f"{label}.extension_tools", errors)
            tools = agent.get("extension_tools")
            if isinstance(tools, list) and (len(tools) != len(set(tools)) or not set(tools) <= set(EXTENSION_TOOLS)):
                errors.append(f"{label}.extension_tools: expected unique names from {sorted(EXTENSION_TOOLS)}")
        if set(agent) != allowed_fields:
            errors.append(f"{label}: expected only {sorted(allowed_fields)}")
    if delegated_agents != MANAGED_SUBAGENT_NAMES:
        errors.append(f"skills/registry.yaml: delegated skills must use {sorted(MANAGED_SUBAGENT_NAMES)}")
    return errors


def native_tool_name(server: str, tool: str) -> str:
    # Match pi-mcp-adapter: do not prefix tools that already start with server_.
    name = tool.replace(".", "_")
    prefix = f"{server}_"
    return name if name.startswith(prefix) and len(name) > len(prefix) else f"{prefix}{name}"


def validate_agent_tools(agents: dict[str, dict[str, Any]], policy: dict[str, Any]) -> list[str]:
    conditional = {
        native_tool_name(server, tool)
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


def validate_snapshot_extension() -> list[str]:
    """Keep the snapshot extension, the permission policy, and the manual fallback in step."""
    errors: list[str] = []
    path = PI_EXTENSIONS_DIR / EXTENSION_TOOLS["b_candidate_snapshot"]
    if not path.is_file():
        return [f"{path.relative_to(ROOT)}: missing managed snapshot extension"]
    text = path.read_text()
    if 'name: "b_candidate_snapshot"' not in text:
        errors.append(f"{path.relative_to(ROOT)}: must register b_candidate_snapshot")
    flags_block = re.search(r"SNAPSHOT_DIFF_FLAGS = \[(.*?)\];", text, re.S)
    flags = re.findall(r'"([^"]+)"', flags_block.group(1)) if flags_block else []
    if not flags:
        errors.append(f"{path.relative_to(ROOT)}: SNAPSHOT_DIFF_FLAGS not found")
    review = (ROOT / "skills" / "b-review" / "prompt.md").read_text()
    for variant in (f"git diff {' '.join(flags)} --cached -- .", f"git diff {' '.join(flags)} -- ."):
        if flags and f"`{variant}`" not in review:
            errors.append(f"skills/b-review/prompt.md: manual fallback must contain `{variant}`")
    rules_block = re.search(r"PROTECTED_RULES[^=]*= \[(.*?)\n\];", text, re.S)
    rules = re.findall(r'\["([^"]+)", "(allow|deny)"\]', rules_block.group(1)) if rules_block else []
    policy_rules = [(pattern, action) for pattern, action in PATH_RULES.items() if pattern != "*"]
    if rules != policy_rules:
        errors.append(f"{path.relative_to(ROOT)}: PROTECTED_RULES must match the permission policy path rules")
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
            errors.append(f"servers.{server}: server name must use Pi MCP-safe spelling")
            continue
        tools = record.get("tools") if isinstance(record, dict) else None
        if not isinstance(tools, dict) or not tools:
            errors.append(f"servers.{server}.tools: expected non-empty object")
            continue
        if record.get("exposure") not in MCP_EXPOSURES:
            errors.append(f"servers.{server}.exposure: expected one of {sorted(MCP_EXPOSURES)}")
        for tool, class_name in tools.items():
            name = native_tool_name(server, str(tool))
            if name in seen_tools:
                errors.append(f"{MCP_OPERATIONS_PATH}: duplicate native tool name {name!r}")
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
                if source_dir != str(PI_AGENTS_DIR.relative_to(ROOT)):
                    errors.append(f"{label}.agent.source: expected generated Pi agent directory")
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
    search_servers = [server for server, record in policy["servers"].items() if record["exposure"] == "search"]
    rows.append("")
    rows.append(
        f'Search-exposed servers ({", ".join(search_servers)}) start inactive in main: call `mcp({{search:"<terms>"}})` (auto-allowed), then the activated `<server>_<tool>` next turn; never `mcp({{tool}})` for reads. Specialists call their listed tools directly.'
    )
    return "\n".join(rows)


def render_delegation(skills: list[dict[str, Any]]) -> str:
    delegated = [skill for skill in skills if skill["execution"]["mode"] == "subagent"]
    lines = [
        "- Delegated skills run only in their named Pi `subagent` type with a bounded task naming the exact skill. Never do their work with main-session tools, even for a quick lookup or when a tool description invites it; if the subagent is unavailable, report the gap and ask. The child reads its `SKILL.md` and returns that skill's own Output format; main evaluates it before any user-facing or worktree action:",
    ]
    lines.extend(f"  - `{skill['name']}` -> `{skill['execution']['agent']}`." for skill in delegated)
    lines.append("- All other skills run in the main session.")
    return "\n".join(lines)


DELEGATION_BOUNDARY_HEADING = "## Delegation boundary"


def render_delegation_boundary(skill: dict[str, Any]) -> str:
    name = skill["name"]
    agent = skill["execution"]["agent"]
    return "\n".join(
        [
            DELEGATION_BOUNDARY_HEADING,
            "",
            f"`{name}` runs only in the `{agent}` subagent.",
            "",
            f"- Main session: reading this file prepares the handoff; it never authorizes running the steps below yourself. Gather the parent-owned evidence, then call `subagent` with agent `{agent}` and a bounded task naming `{name}`. Do not do this skill's work with your own tools, even for a quick, small, or single-lookup request. If the subagent is unavailable or fails, report the gap and ask the user; never fall back to self-execution. Evaluate the returned result before any user-facing or worktree action.",
            f"- `{agent}` child: execute the steps below read-only, return this skill's Output format to the main session, and do not delegate again.",
        ]
    )


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
    if skill["routing"].get("explicit_request"):
        # Explicit-request skills stay out of Pi's automatic skill list; /skill:<name> and /<name> still load them.
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


def render_prompt_file(skill: dict[str, Any]) -> str:
    name = skill["name"]
    execution = skill["execution"]
    lines = ["---", f"description: {json.dumps(skill['use'], ensure_ascii=False)}"]
    if skill.get("argument_hint"):
        lines.append(f"argument-hint: {json.dumps(skill['argument_hint'], ensure_ascii=False)}")
    lines.extend(["---", "", "<!-- Generated from skills/registry.yaml. Do not edit this file. -->", ""])
    if execution["mode"] == "subagent":
        handoff = skill.get("handoff", [])
        preparation = f"First read the installed `skills/{name}/SKILL.md` in the main session only to prepare this handoff; do not run its steps there.\n\n"
        if handoff:
            preparation += (
                "Then, before delegation, gather and pass this parent-owned evidence (or state what is unavailable):\n\n"
                + "\n".join(f"- {item}" for item in handoff)
                + "\n\n"
            )
        lines.append(
            f"{preparation}Delegate this bounded task to the `{execution['agent']}` agent with the `subagent` tool. Name the `{name}` skill explicitly in the child prompt and pass these user arguments: $ARGUMENTS\n\nThe child must read and follow its installed `skills/{name}/SKILL.md`, return that skill's Output format, and stay read-only. Evaluate its result in the main session before taking action. Do not perform this skill's work in the main session, even for a quick or single lookup; if the subagent is unavailable, report the gap and ask."
        )
    elif skill["routing"].get("explicit_request"):
        lines.append(
            f"Read and follow the installed `skills/{name}/SKILL.md` (in the Pi agent directory, default `~/.pi/agent/skills/{name}/SKILL.md`; this skill is hidden from the automatic skill list) before acting on: $ARGUMENTS"
        )
    else:
        lines.append(f"Read and follow the installed `skills/{name}/SKILL.md` before acting on: $ARGUMENTS")
    lines.append("")
    return "\n".join(lines)


def render_agent_file(name: str, agent: dict[str, Any], skills: list[dict[str, Any]]) -> str:
    bound_skills = [
        skill["name"]
        for skill in skills
        if skill["execution"]["mode"] == "subagent" and skill["execution"]["agent"] == name
    ]
    skill_list = " or ".join(f"`{skill}`" for skill in bound_skills)
    model, sep, thinking = agent["model"].partition("#")
    if not sep or thinking not in {"off", "minimal", "low", "medium", "high", "xhigh", "max"}:
        raise SystemExit(f"agents.{name}.model: expected provider/model#thinking")
    read_only_mcp = [
        native_tool_name(server, tool)
        for server, record in load_policy()["servers"].items()
        for tool, class_name in record["tools"].items()
        if class_name == "read-only"
    ]
    return "\n".join(
        [
            "---",
            f"description: {json.dumps(agent['description'])}",
            f"tools: {', '.join(['read', 'grep', 'find', 'ls', 'bash', *read_only_mcp, *agent.get('conditional_tools', []), *agent.get('extension_tools', [])])}",
            f"model: {model}",
            f"thinking: {thinking}",
            *([f"max_turns: {agent['max_turns']}"] if "max_turns" in agent else []),
            "prompt_mode: replace",
            "---",
            "",
            f"You are the b-agentic `{name}` subagent. The main session delegates only {skill_list} to you and has already selected the exact skill; do not route again or launch a nested subagent.",
            "",
            "Read and execute the named skill from the installed Pi `skills/<name>/SKILL.md` for the supplied bounded task. Return that skill's own Output format; do not substitute a profile-specific template. The skill's Delegation boundary directs the main session to delegate; you are the named child, so execute its steps.",
            "",
            "Remain read-only. Do not edit, write, commit, stage, run generators or fixers, or ask the user questions. Do not execute external/shared mutation, local upload, lifecycle, or authentication actions; report the required operation to the main session. A returned result is not authority to change files, commit, push, or report task completion. If a required tool is absent, tell the main session rather than bypassing the allowlist.",
            "",
            "<!-- Managed by b-agentic. Generated from skills/registry.yaml. Do not edit this file. -->",
            "",
        ]
    )


def render_permissions(policy: dict[str, Any]) -> dict[str, Any]:
    # Unknown tools ask. The path gate also applies to recognized MCP arguments;
    # the adapter proxy remains ask-only so it cannot bypass direct-tool rules.
    permissions: dict[str, Any] = {
        "*": "ask",
        "path": dict(PATH_RULES),
        "read": "allow",
        "grep": "allow",
        "find": "allow",
        "ls": "allow",
        "write": "allow",
        "edit": "allow",
        "bash": {
            "*": "allow",
            "git push*": "deny",
            "rtk git push*": "deny",
            "git pull*": "deny",
            "rtk git pull*": "deny",
            "git reset --hard*": "deny",
            "rtk git reset --hard*": "deny",
            "git clean -f*": "deny",
            "rtk git clean -f*": "deny",
            "git branch -D*": "deny",
            "rtk git branch -D*": "deny",
            "rm -rf *": "deny",
            "sudo *": "deny",
            "doas *": "deny",
            "docker system prune*": "deny",
            # New keys follow legacy ask rules on an existing merged install.
            "sudo*": "deny",
            "docker system prun*": "deny",
            # The shell gate matches pipeline commands individually, not pipe text.
            "bash": "deny",
            "sh": "deny",
            "bash -s*": "deny",
            "sh -s*": "deny",
        },
        "external_directory": "ask",
        "external_directory_write": "deny",
        # Invoking a skill only loads instructions; its subsequent tool calls
        # still pass through their own permission and path gates.
        "skill": "allow",
        "subagent": "allow",
        "ask_question": "deny",
        "ask_user_question": "allow",
        # Explicitly allow the requested Magic Context tools, including memory
        # writes; unknown future tools still inherit the global ask rule.
        "ctx_search": "allow",
        "ctx_expand": "allow",
        "ctx_memory": "allow",
        "ctx_note": "allow",
        "ctx_reduce": "allow",
        "todowrite": "allow",
        # Local session messaging via pi-intercom; auto-allowed by user decision.
        "intercom": "allow",
        # Subagent runtime progress notice to its parent; parent treats it as untrusted input.
        "notify_parent": "allow",
        # Subagent ask-back: records a question and ends the child turn; main answers via resume.
        "ask_parent": "allow",
        # Managed read-only extension tools; the extension never hashes, diffs, or returns protected content.
        **dict.fromkeys(EXTENSION_TOOLS, "allow"),
        "mcp": {"*": "ask", "mcp_status": "allow", "mcp_search": "allow", "mcp_describe": "allow"},
    }
    for server, record in policy["servers"].items():
        permissions[f"{server}_*"] = "ask"
        for tool, class_name in record["tools"].items():
            permissions[native_tool_name(server, tool)] = policy["classes"][class_name]["native_permission"]
    return {"permissionReviewLog": False, "yoloMode": False, "permission": permissions}


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
        PI_CONFIGS_DIR / "permission.user.template.json": json.dumps(render_permissions(policy), indent=2) + "\n",
    }
    for skill in skills:
        outputs[ROOT / "skills" / skill["name"] / "SKILL.md"] = render_skill_file(skill)
        outputs[PI_PROMPTS_DIR / f"{skill['name']}.md"] = render_prompt_file(skill)
    for name, agent in agents.items():
        outputs[PI_AGENTS_DIR / f"{name}.md"] = render_agent_file(name, agent, skills)
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
    invalid_handoff[0]["handoff"] = []
    if not any(
        "handoff: expected a non-empty string array" in error for error in validate_skills(invalid_handoff, agents)
    ):
        errors.append("skill regression: empty handoff must fail")
    for skill in skills:
        if skill.get("handoff"):
            prompt = render_prompt_file(skill)
            if any(item not in prompt for item in skill["handoff"]):
                errors.append(f"skill regression: {skill['name']} handoff missing from generated prompt")
    for skill in skills:
        explicit = bool(skill["routing"].get("explicit_request"))
        flagged = "\ndisable-model-invocation: true\n" in render_skill_file(skill)
        if flagged != explicit:
            errors.append(f"skill regression: {skill['name']} disable-model-invocation must match explicit_request")
        if explicit and f"~/.pi/agent/skills/{skill['name']}/SKILL.md" not in render_prompt_file(skill):
            errors.append(f"skill regression: {skill['name']} prompt must name the hidden skill path")
    for skill in skills:
        prompt = render_prompt_file(skill)
        head = prompt.split("\n---\n", 1)[0].splitlines() if prompt.startswith("---\n") else []
        fields = {line.split(": ", 1)[0]: json.loads(line.split(": ", 1)[1]) for line in head[1:] if ": " in line}
        if fields.get("description") != skill["use"]:
            errors.append(f"skill regression: {skill['name']} prompt front matter must carry the registry use")
        if fields.get("argument-hint") != skill.get("argument_hint") or set(fields) - {"description", "argument-hint"}:
            errors.append(f"skill regression: {skill['name']} prompt argument-hint must match the registry")
        if "$ARGUMENTS" not in prompt:
            errors.append(f"skill regression: {skill['name']} prompt must keep $ARGUMENTS")

    for skill in skills:
        rendered = render_skill_file(skill)
        has_boundary = f"\n{DELEGATION_BOUNDARY_HEADING}\n" in rendered
        if skill["execution"]["mode"] == "subagent":
            agent_name = skill["execution"]["agent"]
            required = (
                f"`{skill['name']}` runs only in the `{agent_name}` subagent.",
                "even for a quick, small, or single-lookup request",
                "never fall back to self-execution",
            )
            if not has_boundary or any(clause not in rendered for clause in required):
                errors.append(f"delegation regression: {skill['name']} SKILL.md must carry the strict boundary")
            if "even for a quick or single lookup" not in render_prompt_file(skill):
                errors.append(f"delegation regression: {skill['name']} prompt must forbid main-session execution")
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
    invalid_agent_tools["b-researcher"]["conditional_tools"].append("playwright_browser_click")
    if not validate_agent_tools(invalid_agent_tools, policy):
        errors.append("agent regression: mutating conditional tool must fail")
    invalid_extension_tools = json.loads(json.dumps(agents))
    invalid_extension_tools["b-planner"]["extension_tools"] = ["b_candidate_snapshot"]
    if not validate_skills(skills, invalid_extension_tools):
        errors.append("agent regression: extension tool on a non-reviewer agent must fail")
    invalid_extension_tools = json.loads(json.dumps(agents))
    invalid_extension_tools["b-reviewer"]["extension_tools"] = ["unknown_tool"]
    if not validate_skills(skills, invalid_extension_tools):
        errors.append("agent regression: unknown extension tool must fail")
    errors.extend(validate_snapshot_extension())
    invalid_exposure = json.loads(json.dumps(policy))
    next(iter(invalid_exposure["servers"].values()))["exposure"] = "eager"
    if not validate_policy(invalid_exposure):
        errors.append("MCP policy regression: unknown exposure must fail")
    invalid_policy = json.loads(json.dumps(policy))
    first_server = next(iter(invalid_policy["servers"].values()))
    first_server["tools"]["bad"] = "missing"
    if not validate_policy(invalid_policy):
        errors.append("MCP policy regression: unknown class must fail")
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
        *validate_snapshot_extension(),
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
        print("Generated Pi delivery assets refreshed.")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description="Render native Pi assets from canonical b-agentic sources.")
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
