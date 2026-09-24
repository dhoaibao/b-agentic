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
MANAGED_SUBAGENT_NAMES = {"b-planner", "b-researcher", "b-debugger", "b-reviewer"}
CAPABILITY_KINDS = {"mcp", "agent"}


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
        phase = ensure_string(skill.get("phase"), f"{label}.phase", errors)
        if phase and phase not in PHASES:
            errors.append(f"{label}.phase: expected {sorted(PHASES)}")
        ensure_string(skill.get("use"), f"{label}.use", errors)
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
        if set(agent) != {"description", "model"}:
            errors.append(f"{label}: only description and model are supported")
    if delegated_agents != MANAGED_SUBAGENT_NAMES:
        errors.append(f"skills/registry.yaml: delegated skills must use {sorted(MANAGED_SUBAGENT_NAMES)}")
    return errors


def native_tool_name(server: str, tool: str) -> str:
    # pi-mcp-adapter's formatToolName preserves hyphens and replaces dots.
    return f"{server}_{tool.replace('.', '_')}"


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
    return "\n".join(rows)


def render_delegation(skills: list[dict[str, Any]]) -> str:
    delegated = [skill for skill in skills if skill["execution"]["mode"] == "subagent"]
    main = [skill["name"] for skill in skills if skill["execution"]["mode"] == "main"]
    lines = [
        f"- The main session owns user interaction and worktree changes: {', '.join(f'`{name}`' for name in main)}.",
        "- Delegated skills run through their named Pi `subagent` type; pass a bounded task naming the exact skill. The child reads its installed `SKILL.md` and returns that skill's own Output format; the main session evaluates the result before any user-facing or worktree action:",
    ]
    lines.extend(f"  - `{skill['name']}` -> `{skill['execution']['agent']}`." for skill in delegated)
    lines.append(
        "- Subagents are read-only workflow specialists. They do not ask users questions or launch nested agents."
    )
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
    body = body.replace("{{skill_support_path}}", f"~/.pi/agent/skills/{name}")
    execution = skill["execution"]
    lines = ["---", f"name: {name}"]
    lines.extend(fold_yaml("description", description))
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
    lines = ["<!-- Generated from skills/registry.yaml. Do not edit this file. -->", ""]
    if execution["mode"] == "subagent":
        lines.append(
            f"Delegate this bounded task to the `{execution['agent']}` agent with the `subagent` tool. Name the `{name}` skill explicitly in the child prompt and pass these user arguments: $ARGUMENTS\n\nThe child must read and follow its installed `skills/{name}/SKILL.md`, return that skill's Output format, and stay read-only. Evaluate its result in the main session before taking action."
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
            f"tools: {', '.join(['read', 'grep', 'find', 'ls', 'bash', *read_only_mcp])}",
            f"model: {model}",
            f"thinking: {thinking}",
            "prompt_mode: replace",
            "permission:",
            '  "*": deny',
            "  read: allow",
            "  grep: allow",
            "  find: allow",
            "  ls: allow",
            "  bash:",
            '    "*": deny',
            '    "rtk git status*": allow',
            '    "rtk git diff*": allow',
            '    "git status*": allow',
            '    "git diff*": allow',
            '    "rg *": allow',
            '    "fdfind *": allow',
            "  path:",
            '    "*": allow',
            '    "*.env": deny',
            '    "*.env.*": deny',
            '    "*.env.example": allow',
            '    "*.pem": deny',
            '    "*credentials.*": deny',
            '    "*secrets.*": deny',
            "  external_directory: deny",
            "  mcp:",
            '    "*": deny',
            *[f"  {tool}: allow" for tool in read_only_mcp],
            "---",
            "",
            f"You are the b-agentic `{name}` subagent. The main session delegates only {skill_list} to you and has already selected the exact skill; do not route again or launch a nested subagent.",
            "",
            "Read and execute the named skill from the installed Pi `skills/<name>/SKILL.md` for the supplied bounded task. Return that skill's own Output format; do not substitute a profile-specific template.",
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
        "path": {
            "*": "allow",
            "*.env": "deny",
            "*.env.*": "deny",
            "*.env.example": "allow",
            "*.pem": "deny",
            "*credentials.*": "deny",
            "*secrets.*": "deny",
        },
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
            "rm -rf /*": "deny",
            "sudo *": "ask",
            "docker system prune*": "ask",
            "curl * | sh*": "ask",
            "curl * | bash*": "ask",
        },
        "external_directory": "ask",
        "subagent": "allow",
        "ask_question": "deny",
        "ask_user_question": "allow",
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
    invalid_agents = json.loads(json.dumps(agents))
    invalid_agents["b-planner"].pop("model")
    if not validate_skills(skills, invalid_agents):
        errors.append("agent regression: missing model must fail")
    invalid_capabilities = json.loads(json.dumps(capabilities))
    invalid_capabilities["capabilities"][0].pop("status_signal", None)
    if not validate_capabilities(invalid_capabilities, policy):
        errors.append("capability regression: missing status signal must fail")
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
    errors = [*validate_skills(skills, agents), *validate_policy(policy), *validate_capabilities(capabilities, policy)]
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
