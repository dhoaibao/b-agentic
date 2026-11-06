#!/usr/bin/env python3
"""Render Claude Code and Codex delivery assets from b-agentic's canonical sources."""

from __future__ import annotations

import argparse
import json
import re
import sys
import textwrap
import tomllib
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[2]
SKILL_REGISTRY_PATH = ROOT / "skills" / "registry.yaml"
KERNEL_TEMPLATE_PATH = ROOT / "references" / "kernel.template.md"
MCP_OPERATIONS_PATH = ROOT / "references" / "mcp_operations.yaml"
CAPABILITIES_PATH = ROOT / "references" / "capabilities.yaml"
RUNTIMES_PATH = ROOT / "references" / "runtimes.yaml"
CLAUDE_DIR = ROOT / "claude"
CLAUDE_AGENTS_DIR = CLAUDE_DIR / "agents"
CLAUDE_CONFIGS_DIR = CLAUDE_DIR / "configs"
SETTINGS_TEMPLATE_PATH = CLAUDE_CONFIGS_DIR / "settings.template.json"
SNAPSHOT_CLI_PATH = CLAUDE_DIR / "bin" / "b-candidate-snapshot.mjs"

MAX_KERNEL_BYTES = 12_000
MAX_KERNEL_LINES = 100
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
MANAGED_SUBAGENT_NAMES = {"b-planner", "b-researcher", "b-debugger", "b-auditor", "b-reviewer"}
CAPABILITY_KINDS = {"mcp", "agent", "plugin"}
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
# Pushes that name a destination, PR creation, and `gh auth switch` ask each time; the patterns
# below stay denied, including the destination-less `git push` and `git push origin`.
# Claude Code evaluates deny before ask before allow, so the denies carve
# exceptions out of the ask rules. `*` matches any characters, so every flag and
# protected-branch pattern is anchored on argument boundaries (a leading space,
# or the start of the arguments) to keep names such as `feature-f` or
# `main-fix` pushable. The `git * push` and `gh * pr create` ask forms catch
# global options such as `git -C <dir> push`; those forms are asked about but not
# pattern-denied, except the `git -c <key=value> push` form b-pr uses for HTTPS,
# where force and main or master pushes are denied too. `:branch` delete refspecs
# (a trailing `:*` is the legacy prefix form) and default branches not named main
# or master also stay at the ask prompt.
# Other `gh` commands that change GitHub state are grouped below: the destructive,
# credential, and code-execution ones are denied, the reversible ones ask, and read
# commands (`gh pr view`, a plain `gh api <path>`) stay allowed. Each command also gets
# its `gh * <group> <verb>` global-option form (for example `gh -R o/r release delete`).
DENIED_GH_COMMANDS = (
    "gh pr merge",
    "gh repo delete",
    "gh repo archive",
    "gh repo rename",
    "gh repo edit",
    "gh repo deploy-key add",
    "gh repo deploy-key delete",
    "gh release delete",
    "gh release delete-asset",
    "gh extension install",
    "gh alias set",
    "gh alias import",
    "gh secret set",
    "gh secret delete",
    "gh ssh-key add",
    "gh ssh-key delete",
    "gh gpg-key add",
    "gh gpg-key delete",
    "gh auth login",
    "gh auth logout",
    "gh auth token",
    "gh auth refresh",
)
ASKED_GH_COMMANDS = (
    "gh pr create",
    "gh pr close",
    "gh pr edit",
    "gh auth switch",
    "gh release create",
    "gh release upload",
    "gh release edit",
    "gh variable set",
    "gh variable delete",
    "gh repo create",
    "gh repo fork",
    "gh gist create",
    "gh gist delete",
    "gh issue close",
    "gh issue delete",
    "gh issue edit",
    "gh workflow run",
    "gh workflow disable",
    "gh run delete",
    "gh cache delete",
    "gh label delete",
    "gh codespace delete",
)
# `gh api` mutates through a method or request-body flag; a plain `gh api <path>` read stays allowed.
GH_API_DENIED_METHODS = ("DELETE", "PUT", "PATCH")
GH_API_ASKED_FLAGS = ("-f", "-F", "--field", "--raw-field", "--input", "-X", "--method")


def gh_forms(command: str) -> tuple[str, str]:
    """A `gh` command and its global-option form, such as `gh -R o/r pr merge`."""
    return command, command.replace("gh ", "gh * ", 1)


ASKED_COMMANDS = (
    "git push",
    "git * push",
    *(form for command in ASKED_GH_COMMANDS for form in gh_forms(command)),
)
PROTECTED_BRANCHES = ("main", "master")


def c_push_deny_patterns() -> list[str]:
    """Force and protected-branch denies for `git -c <key=value> push`, the form b-pr uses for HTTPS."""
    head = "git -c * push"
    patterns = []
    for flag in ("-f", "--force*", "+*"):
        patterns += [f"{head} {flag}", f"{head} * {flag}"]
    patterns += [f"{head} -f *", f"{head} * -f *"]
    for branch in PROTECTED_BRANCHES:
        for target in (f"* {branch}", f"*:{branch}", f"*refs/heads/{branch}"):
            patterns += [f"{head} {target}", f"{head} {target} *"]
    return patterns


def gh_flag_deny_patterns() -> list[str]:
    """Denies for `gh auth status` printing a token and `gh api` with a mutating method."""
    patterns = []
    for base in gh_forms("gh auth status"):
        patterns += [f"{base} *--show-token*"]
        patterns += [f"{base} -t", f"{base} -t *", f"{base} * -t", f"{base} * -t *"]
    # The method value must directly follow the flag (`-X DELETE`, `-XDELETE`, `-X=DELETE`,
    # `--method DELETE`, `--method=DELETE`), so a method word in an endpoint or field stays allowed.
    flag_forms = ("-X ", "-X", "-X=", "--method ", "--method=")
    for base in gh_forms("gh api"):
        for form in flag_forms:
            for method in GH_API_DENIED_METHODS:
                patterns += [f"{base} *{form}{method}*", f"{base} *{form}{method.lower()}*"]
    return patterns


def gh_api_ask_patterns() -> list[str]:
    """Asks for `gh api` calls that send a request body or choose a method."""
    patterns = []
    for base in gh_forms("gh api"):
        for flag in GH_API_ASKED_FLAGS:
            patterns += [f"{base} {flag}*", f"{base} * {flag}*"]
    return patterns


def push_deny_patterns() -> tuple[str, ...]:
    patterns = ["git push", "git push origin"]
    for flag in ("-f", "-d"):
        patterns += [f"git push {flag}", f"git push {flag} *", f"git push * {flag}", f"git push * {flag} *"]
    for flag in ("--force*", "--delete*", "--mirror*", "--all*", "--branches*", "--prune*", "+*"):
        patterns += [f"git push {flag}", f"git push * {flag}"]
    for branch in PROTECTED_BRANCHES:
        for target in (f"* {branch}", f"*:{branch}", f"*refs/heads/{branch}"):
            patterns += [f"git push {target}", f"git push {target} *"]
    patterns += c_push_deny_patterns()
    for command in DENIED_GH_COMMANDS:
        for form in gh_forms(command):
            patterns += [form, f"{form} *"]
    patterns += gh_flag_deny_patterns()
    return tuple(patterns)


DENIED_PUSH_PATTERNS = push_deny_patterns()
DENIED_COMMANDS = (
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


def load_runtimes() -> dict[str, dict[str, Any]]:
    runtimes = load_json_subset_yaml(RUNTIMES_PATH).get("runtimes")
    if not isinstance(runtimes, dict) or not isinstance(runtimes.get("claude"), dict):
        raise SystemExit(f"{RUNTIMES_PATH}: missing runtimes object with a claude entry")
    return runtimes


RUNTIMES = load_runtimes()
CLAUDE_RUNTIME = RUNTIMES["claude"]
AGENT_MODELS = set(CLAUDE_RUNTIME["agent_models"])
# Effort levels Claude Code accepts in subagent frontmatter (support varies by model).
AGENT_EFFORTS = {"low", "medium", "high", "xhigh", "max"}
# Codex reasoning efforts (the 0.167.0 model catalog lists up to `ultra`) and a Codex model slug.
CODEX_EFFORTS = {"low", "medium", "high", "xhigh", "max", "ultra"}
CODEX_MODEL_PATTERN = re.compile(r"[a-z0-9][a-z0-9.-]*")
# Tools a read-only specialist must never receive, whatever the registry says.
EDITING_TOOLS = tuple(CLAUDE_RUNTIME["editing_tools"])
# Canonical sources name MCP tools the Claude Code way; other runtimes get their own format.
MCP_REFERENCE_PATTERN = re.compile(r"mcp__([a-z][a-z0-9_]*)__([A-Za-z0-9_.*-]+)")


def localize(text: str, runtime: str) -> str:
    """Render canonical Claude Code wording for a runtime; the claude runtime is the identity."""
    config = RUNTIMES[runtime]
    for source, target in sorted(config["glossary"], key=lambda pair: len(pair[0]), reverse=True):
        text = text.replace(source, target)
    return MCP_REFERENCE_PATTERN.sub(
        lambda match: config["mcp_tool_format"].format(server=match[1], tool=match[2]), text
    )


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
    return CLAUDE_RUNTIME["mcp_tool_format"].format(server=server, tool=tool)


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
    if len(text.encode()) > MAX_KERNEL_BYTES:
        errors.append(f"{KERNEL_TEMPLATE_PATH}: exceeds {MAX_KERNEL_BYTES:,} byte kernel budget")
    if len(text.splitlines()) > MAX_KERNEL_LINES:
        errors.append(f"{KERNEL_TEMPLATE_PATH}: exceeds {MAX_KERNEL_LINES} line kernel budget")


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
        if "effort" in agent:
            allowed_fields.add("effort")
            effort = ensure_string(agent["effort"], f"{label}.effort", errors)
            if effort and effort not in AGENT_EFFORTS:
                errors.append(f"{label}.effort: expected one of {sorted(AGENT_EFFORTS)}")
        for field in ("codex_model", "codex_effort"):
            if field not in agent:
                continue
            allowed_fields.add(field)
            value = ensure_string(agent[field], f"{label}.{field}", errors)
            if value and field == "codex_effort" and value not in CODEX_EFFORTS:
                errors.append(f"{label}.{field}: expected one of {sorted(CODEX_EFFORTS)}")
            if value and field == "codex_model" and not CODEX_MODEL_PATTERN.fullmatch(value):
                errors.append(f"{label}.{field}: expected a model slug such as gpt-6.1-sol")
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
    """Keep the snapshot CLI and the path rules in step."""
    errors: list[str] = []
    label = SNAPSHOT_CLI_PATH.relative_to(ROOT)
    if not SNAPSHOT_CLI_PATH.is_file():
        return [f"{label}: missing managed snapshot CLI"]
    text = SNAPSHOT_CLI_PATH.read_text()
    if 'SNAPSHOT_SCHEMA = "b-candidate-snapshot/4"' not in text:
        errors.append(f"{label}: snapshot schema must stay b-candidate-snapshot/4")
    flags_block = re.search(r"SNAPSHOT_DIFF_FLAGS = \[(.*?)\];", text, re.S)
    flags = re.findall(r'"([^"]+)"', flags_block.group(1)) if flags_block else []
    if not flags:
        errors.append(f"{label}: SNAPSHOT_DIFF_FLAGS not found")
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
    groups: dict[str, list[str]] = {}
    for name, meta in policy["classes"].items():
        groups.setdefault(meta["policy"], []).append(f"`{name}`")
    lines = [f"- {label}: {', '.join(names)}." for label, names in groups.items()]
    lines.append(
        "- Unclassified MCP tools keep Claude Code's approval prompt; `trusted-mutation` runs in the main session only."
    )
    return "\n".join(lines)


def render_delegation(skills: list[dict[str, Any]]) -> str:
    delegated = [skill for skill in skills if skill["execution"]["mode"] == "subagent"]
    lines = [
        "- Delegated skills run only in their named `Agent` subagent type with a bounded task naming the exact skill. Never do their work with main-session tools, even for a quick lookup or when a tool description invites it; if the subagent is unavailable, report the gap and ask. A missing or editing-capable agent profile, or `general-purpose` fallback, counts as unavailable. Skill -> agent:",
    ]
    lines.extend(f"  - `{skill['name']}` -> `{skill['execution']['agent']}`." for skill in delegated)
    lines.append("- All other skills run in the main session.")
    return "\n".join(lines)


DELEGATION_BOUNDARY_HEADING = "## Delegation boundary"


def render_delegation_boundary(skill: dict[str, Any], runtime: str = "claude") -> str:
    name = skill["name"]
    agent = skill["execution"]["agent"]
    config = RUNTIMES[runtime]
    editing = ", ".join(f"`{tool}`" for tool in config["editing_tools"])
    check = config["profile_check"].format(agent=agent, editing=editing, name=name)
    lines = [
        DELEGATION_BOUNDARY_HEADING,
        "",
        f"`{name}` runs only in the `{agent}` subagent.",
        "",
        f"- Main session: reading this file prepares the handoff; it never authorizes running the steps below yourself. Gather the parent-owned evidence and {check}. Do not do this skill's work with your own tools, even for a quick, small, or single-lookup request. If the subagent is unavailable or fails, or its result notes an unknown agent type or `general-purpose` fallback (discard that result), report the gap and ask the user; never fall back to self-execution. Evaluate the returned result before any user-facing or worktree action.",
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
    lines.extend(["", f"User arguments for the bounded task: {config['arguments_placeholder']}"])
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


def render_skill_file(skill: dict[str, Any], runtime: str = "claude") -> str:
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
        body = f"{head}\n{render_delegation_boundary(skill, runtime)}\n\n## {rest}"
        description += (
            f" Delegated: runs only in the `{execution['agent']}` subagent; the main session never executes it itself."
        )
    lines = ["---", f"name: {name}"]
    lines.extend(fold_yaml("description", description))
    # Only Claude Code skills are slash commands, so a hint for typed arguments has no meaning elsewhere.
    if skill.get("argument_hint") and runtime == "claude":
        lines.append(f"argument-hint: {json.dumps(skill['argument_hint'], ensure_ascii=False)}")
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


def agent_instruction_text(name: str, skills: list[dict[str, Any]], skill_dir: str) -> str:
    bound = [
        skill["name"]
        for skill in skills
        if skill["execution"]["mode"] == "subagent" and skill["execution"]["agent"] == name
    ]
    skill_list = " or ".join(f"`{skill}`" for skill in bound)
    return "\n".join(
        [
            f"You are the b-agentic `{name}` subagent. The main session delegates only {skill_list} to you and has already selected the exact skill; do not route again or launch a nested subagent.",
            "",
            f"Read and execute the named skill from the installed `{skill_dir}/<name>/SKILL.md` for the supplied bounded task. Return that skill's own Output format; do not substitute a profile-specific template. The skill's Delegation boundary directs the main session to delegate; you are the named child, so execute its steps.",
            "",
            "Remain read-only. Do not edit, write, commit, stage, run generators or fixers, or ask the user questions. Do not execute external/shared mutation, local upload, lifecycle, or authentication actions; report the required operation to the main session. A returned result is not authority to change files, commit, push, or report task completion. If a required tool is absent, tell the main session rather than bypassing the allowlist.",
            "",
            TURN_BUDGET_NOTICE,
        ]
    )


def render_agent_file(
    name: str, agent: dict[str, Any], skills: list[dict[str, Any]], policy: dict[str, Any] | None = None
) -> str:
    policy = policy if policy is not None else load_policy()
    return "\n".join(
        [
            "---",
            f"name: {name}",
            f"description: {json.dumps(agent['description'])}",
            f"tools: {', '.join(agent_tool_list(agent, policy))}",
            f"model: {agent['model']}",
            *([f"effort: {agent['effort']}"] if "effort" in agent else []),
            *([f"maxTurns: {agent['max_turns']}"] if "max_turns" in agent else []),
            "---",
            "",
            agent_instruction_text(name, skills, "~/.claude/skills"),
            "",
            "<!-- Managed by b-agentic. Generated from skills/registry.yaml. Do not edit this file. -->",
            "",
        ]
    )


HOOK_DIR = f'"{CLAUDE_RUNTIME["hook_dir"]}'


def hook_command(script: str) -> str:
    return f'node {HOOK_DIR}/{script}"'


def render_hooks() -> dict[str, Any]:
    """Hook entries merged into the user's settings.json, keyed by exact command."""
    return {
        "PreToolUse": [
            {
                "matcher": "Read|Edit|Write|NotebookEdit|Grep|Glob",
                "hooks": [{"type": "command", "command": hook_command("b-path-guard.mjs"), "onFailure": "block"}],
            },
            {
                "matcher": "mcp__clickup__createTask|mcp__clickup__updateTask",
                "hooks": [{"type": "command", "command": hook_command("b-clickup-guard.mjs"), "onFailure": "block"}],
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


def render_status_line() -> dict[str, Any]:
    """The status line entry set in the user's settings.json only when none is configured."""
    bin_dir = str(CLAUDE_RUNTIME["hook_dir"]).removesuffix("/hooks") + "/bin"
    return {"type": "command", "command": f'node "{bin_dir}/b-statusline.mjs"', "refreshInterval": 5}


def render_settings(policy: dict[str, Any]) -> dict[str, Any]:
    return {**render_permissions(policy), "hooks": render_hooks(), "statusLine": render_status_line()}


def shell_pattern_rules() -> tuple[list[str], list[str]]:
    """Shell command patterns the settings layer asks about and denies, as (ask, deny)."""
    deny: list[str] = []
    ask: list[str] = []
    for command in DENIED_COMMANDS:
        for prefix in ("", "rtk "):
            deny.extend([f"{prefix}{command}", f"{prefix}{command} *"])
    for pattern in DENIED_PUSH_PATTERNS:
        for prefix in ("", "rtk "):
            deny.append(f"{prefix}{pattern}")
    for command in ASKED_COMMANDS:
        for prefix in ("", "rtk "):
            ask.extend([f"{prefix}{command}", f"{prefix}{command} *"])
    for pattern in gh_api_ask_patterns():
        for prefix in ("", "rtk "):
            ask.append(f"{prefix}{pattern}")
    deny.extend(DENIED_BARE_COMMANDS)
    return ask, deny


def render_permissions(policy: dict[str, Any]) -> dict[str, Any]:
    """Permission rules merged into the user's Claude Code settings.json."""
    allow = list(ALLOWED_TOOLS)
    shell_ask, shell_deny = shell_pattern_rules()
    ask = [f"Bash({pattern})" for pattern in shell_ask]
    deny = [f"Bash({pattern})" for pattern in shell_deny]
    # Claude Code warns about and ignores Write(path) rules: Edit(path) rules cover every file-editing tool.
    for tool in ("Read", "Edit"):
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


CODEX_DIR = ROOT / "codex"
CODEX_AGENTS_DIR = CODEX_DIR / "agents"
CODEX_SKILLS_DIR = CODEX_DIR / "skills"
CODEX_CONFIGS_DIR = CODEX_DIR / "configs"
CODEX_RULES_PATH = CODEX_DIR / "rules" / "b-agentic.rules"
CODEX_REFERENCES_DIR = CODEX_DIR / "references"
CODEX_KERNEL_PATH = CODEX_CONFIGS_DIR / "kernel.md"
CODEX_CONFIG_PATH = CODEX_CONFIGS_DIR / "config.template.toml"
CODEX_CLICKUP_PATH = CODEX_CONFIGS_DIR / "config.clickup.toml"
CODEX_HOOKS_PATH = CODEX_CONFIGS_DIR / "hooks.template.json"
CODEX_SPECIALIST_TOOLS_PATH = CODEX_REFERENCES_DIR / "specialist-tools.json"
CODEX_APPROVAL_MODES = ("auto", "prompt", "writes", "approve")
# A Codex PreToolUse hook cannot ask, so the ClickUp image-reference guard is not ported and
# these two tools prompt on every call instead of running unprompted.
CODEX_ASKED_TOOLS = (("clickup", "createTask"), ("clickup", "updateTask"))
CODEX_HOOK_SCRIPT = "b-codex-hooks.mjs"
CODEX_RUNTIME_HOOK_DIR = RUNTIMES["codex"]["hook_dir"]
ENV_REFERENCE = re.compile(r"\$\{([A-Z0-9_]+)\}")
TOML_BARE_KEY = re.compile(r"[A-Za-z0-9_-]+")


def toml_key(key: str) -> str:
    return key if TOML_BARE_KEY.fullmatch(key) else json.dumps(key)


def toml_string(text: str) -> str:
    """A TOML string: a readable multi-line literal when safe, else a JSON-escaped basic string."""
    if (
        "\n" in text
        and "'''" not in text
        and not text.endswith("'")
        and not re.search(r"[\x00-\x08\x0b-\x1f\x7f\r]", text)
    ):
        return "'''\n" + text + "'''"
    return json.dumps(text, ensure_ascii=False)


def toml_value(value: Any) -> str:
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, int):
        return str(value)
    if isinstance(value, str):
        return toml_string(value)
    if isinstance(value, list):
        return "[" + ", ".join(toml_value(item) for item in value) + "]"
    raise TypeError(f"unsupported TOML value: {value!r}")


def codex_tool_mode(policy: dict[str, Any], server: str, class_name: str, tool: str) -> str | None:
    """The approval_mode for a classified tool, or None when the policy denies it outright."""
    if (server, tool) in CODEX_ASKED_TOOLS:
        return "prompt"
    return {"allow": "approve", "ask": "prompt"}.get(policy["classes"][class_name]["native_permission"])


def codex_server_tables(name: str, entry: dict[str, Any], policy: dict[str, Any]) -> list[str]:
    """One managed MCP server as Codex config.toml tables; credentials stay environment references."""
    key = toml_key(name)
    lines = [f"[mcp_servers.{key}]"]
    literal: dict[str, str] = {}
    from_env: dict[str, str] = {}
    mapping = entry.get("env", {}) if entry["type"] == "stdio" else entry.get("headers", {})
    for field, value in mapping.items():
        reference = ENV_REFERENCE.fullmatch(value)
        if reference:
            if entry["type"] == "stdio" and reference[1] != field:
                # `env_vars` forwards a variable under its own name, so a renamed reference has no Codex form.
                raise SystemExit(
                    f"mcp template {name}.{field}: a stdio env reference must use the same name, not ${{{reference[1]}}}"
                )
            from_env[field] = reference[1]
        elif ENV_REFERENCE.search(value):
            raise SystemExit(f"mcp template {name}.{field}: a ${{VAR}} reference must be the whole value")
        else:
            literal[field] = value
    if entry["type"] == "stdio":
        lines.append(f"command = {toml_value(entry['command'])}")
        if entry.get("args"):
            lines.append(f"args = {toml_value(entry['args'])}")
        if from_env:
            lines.append(f"env_vars = {toml_value(list(from_env.values()))}")
    else:
        lines.append(f"url = {toml_value(entry['url'])}")
    lines.append('default_tools_approval_mode = "prompt"')
    tools = policy["servers"].get(name, {}).get("tools", {})
    modes = {tool: codex_tool_mode(policy, name, class_name, tool) for tool, class_name in tools.items()}
    disabled = [tool for tool, mode in modes.items() if mode is None]
    if disabled:
        lines.append(f"disabled_tools = {toml_value(disabled)}")
    if literal:
        table = "env" if entry["type"] == "stdio" else "http_headers"
        lines += ["", f"[mcp_servers.{key}.{table}]", *[f"{toml_key(f)} = {toml_value(v)}" for f, v in literal.items()]]
    if from_env and entry["type"] != "stdio":
        lines += [
            "",
            f"[mcp_servers.{key}.env_http_headers]",
            *[f"{toml_key(f)} = {toml_value(v)}" for f, v in from_env.items()],
        ]
    for tool, mode in modes.items():
        if mode is not None:
            lines += ["", f"[mcp_servers.{key}.tools.{toml_key(tool)}]", f"approval_mode = {toml_value(mode)}"]
    return lines


def render_codex_config(path: Path, policy: dict[str, Any]) -> str:
    servers = json.loads(path.read_text())["mcpServers"]
    blocks = ["\n".join(codex_server_tables(name, entry, policy)) for name, entry in servers.items()]
    return "\n\n".join(blocks) + "\n"


def render_codex_hooks() -> dict[str, Any]:
    command = f'node "{CODEX_RUNTIME_HOOK_DIR}/{CODEX_HOOK_SCRIPT}"'
    hook = {"type": "command", "command": command, "timeout": 10}
    return {
        "hooks": {
            "PreToolUse": [{"matcher": "apply_patch|Edit|Write|Bash|mcp__.*", "hooks": [hook]}],
            "PostToolUse": [{"matcher": "apply_patch|Edit|Write|Bash", "hooks": [hook]}],
            "Stop": [{"hooks": [hook]}],
        }
    }


def split_command(command: str) -> list[str]:
    """A shell command pattern as a Codex prefix pattern; wildcard forms have no prefix equivalent."""
    return command.split()


def codex_rule_head(pattern: list[str], decision: str) -> str:
    tokens = ", ".join(json.dumps(token) for token in pattern)
    return f"pattern = [{tokens}],\n    decision = {json.dumps(decision)},"


def codex_rule(pattern: list[str], decision: str, justification: str) -> str:
    tokens = ", ".join(json.dumps(token) for token in pattern)
    return (
        "prefix_rule(\n"
        f"    {codex_rule_head(pattern, decision)}\n"
        f"    justification = {json.dumps(justification)},\n"
        f"    match = [[{tokens}]],\n"
        ")\n"
    )


CODEX_PUSH_FORBIDDEN = (
    ("git", "push", "--force"),
    ("git", "push", "-f"),
    ("git", "push", "--delete"),
    ("git", "push", "-d"),
    ("git", "push", "--mirror"),
    ("git", "push", "--all"),
    ("git", "push", "--prune"),
    *(("git", "push", "origin", branch) for branch in PROTECTED_BRANCHES),
)


def codex_rule_patterns() -> tuple[list[list[str]], list[list[str]]]:
    """Prefix patterns for (forbidden, prompt). Codex rules match an exact argument prefix, so only
    the adjacent forms of the Claude Code shell rules carry over; the rest is a documented gap."""
    forbidden = [split_command(command) for command in (*DENIED_COMMANDS, *DENIED_GH_COMMANDS)]
    forbidden += [list(pattern) for pattern in CODEX_PUSH_FORBIDDEN]
    prompt = [split_command(command) for command in ("git push", *ASKED_GH_COMMANDS)]
    return forbidden, prompt


def render_codex_rules() -> str:
    forbidden, prompt = codex_rule_patterns()
    header = [
        "# Managed by b-agentic. Generated from tooling/generate/registry_sync.py. Do not edit this file.",
        "# Codex rules match an exact argument prefix: a flag that is not directly after the prefix,",
        "# a `gh` global option, or a refspec elsewhere in the command is not matched.",
        "",
    ]
    blocks = []
    for patterns, decision, reason in (
        (forbidden, "forbidden", "blocked by b-agentic: a destructive, privileged, or default-branch command"),
        (prompt, "prompt", "b-agentic asks before a push or a GitHub state change"),
    ):
        for pattern in patterns:
            for prefix in ([], ["rtk"]):
                blocks.append(codex_rule([*prefix, *pattern], decision, reason))
    return "\n".join([*header, *blocks])


def codex_specialist_tools(agents: dict[str, dict[str, Any]], policy: dict[str, Any]) -> dict[str, list[str]]:
    return {
        name: [tool for tool in agent_tool_list(agent, policy) if tool.startswith("mcp__")]
        for name, agent in agents.items()
    }


CODEX_READ_ONLY_NOTICE = (
    "Codex cannot restrict this role's tools, so read-only is your obligation: a hook denies `apply_patch` and "
    "MCP tools outside your allowlist, but you must also avoid shell redirection, `sed -i`, and any other command "
    "that writes, stages, or mutates state."
)


def render_codex_agent_file(name: str, agent: dict[str, Any], skills: list[dict[str, Any]]) -> str:
    instructions = localize(agent_instruction_text(name, skills, "~/.claude/skills"), "codex")
    instructions += "\n\n" + CODEX_READ_ONLY_NOTICE
    return "\n".join(
        [
            "# Managed by b-agentic. Generated from skills/registry.yaml. Do not edit this file.",
            f"name = {toml_value(name)}",
            f"description = {toml_value(agent['description'])}",
            *([f"model = {toml_value(agent['codex_model'])}"] if "codex_model" in agent else []),
            *([f"model_reasoning_effort = {toml_value(agent['codex_effort'])}"] if "codex_effort" in agent else []),
            f"developer_instructions = {toml_value(instructions + chr(10))}",
            "",
        ]
    )


def render_codex_references(policy: dict[str, Any]) -> dict[Path, str]:
    """Deliver effective runtime policy, not Claude-only approvals or capability paths."""
    effective_policy = {
        **policy,
        "description": "MCP operation classification for Codex. Tools use mcp__<server>__<tool>; managed servers prompt by default and unclassified tools prompt.",
        "classes": {name: dict(meta) for name, meta in policy["classes"].items()},
        "runtime_enforcement": {"codex": policy["runtime_enforcement"]["codex"]},
    }
    capabilities = json.loads(localize(json.dumps(load_capabilities()), "codex"))
    capabilities["description"] = capabilities["description"].replace("Claude Code", "Codex")
    for capability in capabilities["capabilities"]:
        if capability["kind"] != "plugin":
            for key in ("purpose", "readiness", "fallback"):
                capability[key] = capability[key].replace("Claude Code", "Codex")
            capability["prerequisites"] = [item.replace("Claude Code", "Codex") for item in capability["prerequisites"]]
        for key, value in capability.get("source", {}).items():
            if value == "tooling/install/claude_install.py":
                capability["source"][key] = "tooling/install/codex_install.py"
            elif value == "claude/agents":
                capability["source"][key] = "codex/agents"
            elif value.startswith("claude/configs/mcp."):
                name = "config.clickup.toml" if value.endswith("clickup.json") else "config.template.toml"
                capability["source"][key] = f"codex/configs/{name}"
        if capability["kind"] == "agent":
            capability["agent"]["source"] = "codex/agents"
    return {
        CODEX_REFERENCES_DIR / name: json.dumps(value, indent=2) + "\n"
        for name, value in (("mcp_operations.yaml", effective_policy), ("capabilities.yaml", capabilities))
    }


def render_codex_outputs(
    skills: list[dict[str, Any]],
    agents: dict[str, dict[str, Any]],
    policy: dict[str, Any],
    kernel: str,
) -> dict[Path, str]:
    outputs = {
        CODEX_KERNEL_PATH: localize(kernel, "codex"),
        CODEX_CONFIG_PATH: render_codex_config(CLAUDE_CONFIGS_DIR / "mcp.base.json", policy),
        CODEX_CLICKUP_PATH: render_codex_config(CLAUDE_CONFIGS_DIR / "mcp.clickup.json", policy),
        CODEX_HOOKS_PATH: json.dumps(render_codex_hooks(), indent=2) + "\n",
        CODEX_RULES_PATH: render_codex_rules(),
        CODEX_SPECIALIST_TOOLS_PATH: json.dumps(codex_specialist_tools(agents, policy), indent=2) + "\n",
        **render_codex_references(policy),
    }
    for skill in skills:
        outputs[CODEX_SKILLS_DIR / skill["name"] / "SKILL.md"] = localize(render_skill_file(skill, "codex"), "codex")
    for name, agent in agents.items():
        outputs[CODEX_AGENTS_DIR / f"{name}.toml"] = render_codex_agent_file(name, agent, skills)
    return outputs


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
    outputs.update(render_codex_outputs(skills, agents, policy, kernel))
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
        if "\ndisable-model-invocation:" in render_skill_file(skill):
            errors.append(f"skill regression: {skill['name']} must not set disable-model-invocation")
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
    for bad_effort in (None, True, 42, "", "extreme", "XHIGH"):
        invalid_agents = json.loads(json.dumps(agents))
        invalid_agents["b-planner"]["effort"] = bad_effort
        if not any("effort" in error for error in validate_skills(skills, invalid_agents)):
            errors.append(f"agent regression: invalid effort {bad_effort!r} must fail")
    for effort in (None, "low", "medium", "high", "xhigh", "max"):
        candidate_agents = json.loads(json.dumps(agents))
        candidate = candidate_agents["b-planner"]
        candidate.pop("effort", None)
        if effort is not None:
            candidate["effort"] = effort
        if validate_skills(skills, candidate_agents):
            errors.append(f"agent regression: valid effort {effort!r} must pass")
        rendered = render_agent_file("b-planner", candidate, skills, policy)
        if re.findall(r"^effort: (.+)$", rendered, re.MULTILINE) != ([effort] if effort is not None else []):
            errors.append(f"agent regression: Claude must render effort {effort!r}, or omit it when unset")
    for field, bad_values in (
        ("codex_model", (None, True, 42, "", "Sol", "gpt 6", "-sol")),
        ("codex_effort", (None, True, 42, "", "extreme", "XHIGH")),
    ):
        for bad in bad_values:
            invalid_agents = json.loads(json.dumps(agents))
            invalid_agents["b-planner"][field] = bad
            if not any(field in error for error in validate_skills(skills, invalid_agents)):
                errors.append(f"agent regression: invalid {field} {bad!r} must fail")
    for model, effort in ((None, None), ("gpt-6.1-sol", None), (None, "ultra"), ("gpt-6.1-terra", "low")):
        candidate_agents = json.loads(json.dumps(agents))
        candidate = candidate_agents["b-planner"]
        candidate.pop("codex_model", None)
        candidate.pop("codex_effort", None)
        for field, value in (("codex_model", model), ("codex_effort", effort)):
            if value is not None:
                candidate[field] = value
        if validate_skills(skills, candidate_agents):
            errors.append(f"agent regression: valid codex pins {model!r}/{effort!r} must pass")
        if render_agent_file("b-planner", candidate, skills, policy) != render_agent_file(
            "b-planner", agents["b-planner"], skills, policy
        ):
            errors.append("agent regression: codex pins must not change Claude output")
        rendered = render_codex_agent_file("b-planner", candidate, skills)
        if re.findall(r"^model = (.+)$", rendered, re.MULTILINE) != (
            [json.dumps(model)] if model else []
        ) or re.findall(r"^model_reasoning_effort = (.+)$", rendered, re.MULTILINE) != (
            [json.dumps(effort)] if effort else []
        ):
            errors.append(f"agent regression: Codex must render pins {model!r}/{effort!r}, or inherit when unset")
    for name, agent in agents.items():
        rendered = render_agent_file(name, agent, skills, policy)
        if TURN_BUDGET_NOTICE not in rendered:
            errors.append(f"agent regression: {name} profile must carry the turn-budget wrap-up notice")
        tools = agent_tool_list(agent, policy)
        if any(tool in tools for tool in EDITING_TOOLS) or {"Agent", "Task", "AskUserQuestion"} & set(tools):
            errors.append(f"agent regression: {name} profile must stay read-only, non-delegating, and non-interactive")
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


def validate_runtimes() -> list[str]:
    errors: list[str] = []
    for name, config in RUNTIMES.items():
        label = f"{RUNTIMES_PATH.relative_to(ROOT)}: runtimes.{name}"
        for key in ("config_dir", "state_dir", "hook_dir", "mcp_tool_format"):
            ensure_string(config.get(key), f"{label}.{key}", errors)
        for key in ("agent_models", "editing_tools"):
            if not isinstance(config.get(key), list) or not all(isinstance(item, str) and item for item in config[key]):
                errors.append(f"{label}.{key}: expected a string array")
        template = config.get("mcp_tool_format")
        if isinstance(template, str) and not ("{server}" in template and "{tool}" in template):
            errors.append(f"{label}.mcp_tool_format: must contain {{server}} and {{tool}}")
        glossary = config.get("glossary")
        if not isinstance(glossary, list) or not all(
            isinstance(pair, list) and len(pair) == 2 and all(isinstance(part, str) and part for part in pair)
            for pair in glossary
        ):
            errors.append(f"{label}.glossary: expected an array of [source, replacement] string pairs")
            continue
        sources = [pair[0] for pair in glossary]
        if len(set(sources)) != len(sources):
            errors.append(f"{label}.glossary: duplicate source entries")
        forbidden = config.get("forbidden_terms", [])
        if not isinstance(forbidden, list) or not all(isinstance(term, str) and term for term in forbidden):
            errors.append(f"{label}.forbidden_terms: expected a string array")
        elif name != "claude" and not forbidden:
            errors.append(f"{label}.forbidden_terms: a localized runtime must list the Claude-only terms to shed")
    claude = RUNTIMES["claude"]
    if claude.get("glossary") != [] or claude.get("mcp_tool_format") != "mcp__{server}__{tool}":
        errors.append(
            "runtimes.claude: canonical sources are Claude Code wording, so its glossary must be empty and MCP format mcp__{server}__{tool}"
        )
    return errors


def parse_toml(text: str, label: str, errors: list[str]) -> dict[str, Any]:
    try:
        return tomllib.loads(text)
    except tomllib.TOMLDecodeError as exc:
        errors.append(f"{label}: invalid TOML ({exc})")
        return {}


def validate_codex_outputs(
    outputs: dict[Path, str], agents: dict[str, dict[str, Any]], policy: dict[str, Any]
) -> list[str]:
    """Structural checks on the rendered Codex assets: parseable TOML, an asking default per managed MCP
    server, class-faithful approval modes, read-only specialist profiles, and a complete rule set."""
    errors: list[str] = []
    kernel = outputs[CODEX_KERNEL_PATH]
    if len(kernel.encode()) > MAX_KERNEL_BYTES or len(kernel.splitlines()) > MAX_KERNEL_LINES:
        errors.append("codex/configs/kernel.md: exceeds the kernel size limit")
    forbidden_terms = RUNTIMES["codex"]["forbidden_terms"]
    for path, text in outputs.items():
        if not path.is_relative_to(CODEX_DIR) or path.suffix not in {".md"}:
            continue
        for term in forbidden_terms:
            if term in text:
                errors.append(f"{path.relative_to(ROOT)}: Codex rendering still contains {term!r}")
        if re.search(r"`/b-(?:[a-z][a-z0-9-]*|<name>)`", text):
            errors.append(f"{path.relative_to(ROOT)}: Codex skills must not recommend slash commands")
        if path.name == "SKILL.md" and ("argument-hint:" in text or "$ARGUMENTS" in text):
            errors.append(
                f"{path.relative_to(ROOT)}: Codex skills are not slash commands; no argument hint or $ARGUMENTS"
            )
    expected_servers: dict[str, str] = {}
    for template, path in (("mcp.base.json", CODEX_CONFIG_PATH), ("mcp.clickup.json", CODEX_CLICKUP_PATH)):
        config = parse_toml(outputs[path], str(path.relative_to(ROOT)), errors).get("mcp_servers", {})
        template_servers = json.loads((CLAUDE_CONFIGS_DIR / template).read_text())["mcpServers"]
        if set(config) != set(template_servers):
            errors.append(f"{path.relative_to(ROOT)}: servers must match claude/configs/{template}")
        for server, table in config.items():
            label = f"{path.relative_to(ROOT)}: {server}"
            if table.get("default_tools_approval_mode") != "prompt":
                errors.append(f"{label} must prompt by default (default_tools_approval_mode)")
            tools = policy["servers"].get(server, {}).get("tools", {})
            declared = table.get("tools", {})
            disabled = set(table.get("disabled_tools", []))
            for tool, class_name in tools.items():
                expected = codex_tool_mode(policy, server, class_name, tool)
                if expected is None:
                    if tool not in disabled:
                        errors.append(f"{label}.{tool} must be disabled")
                elif declared.get(tool, {}).get("approval_mode") != expected:
                    errors.append(f"{label}.{tool} must be approval_mode {expected!r}")
            for tool, entry in declared.items():
                if tool not in tools:
                    errors.append(f"{label}.{tool}: tool table for an unclassified tool")
                if entry.get("approval_mode") not in CODEX_APPROVAL_MODES:
                    errors.append(f"{label}.{tool}: invalid approval_mode {entry.get('approval_mode')!r}")
            expected_servers[server] = path.name
    for server, tool in CODEX_ASKED_TOOLS:
        if codex_tool_mode(policy, server, policy["servers"][server]["tools"][tool], tool) != "prompt":
            errors.append(f"{server}.{tool} must prompt on every call")
    for name, agent in agents.items():
        path = CODEX_AGENTS_DIR / f"{name}.toml"
        data = parse_toml(outputs[path], str(path.relative_to(ROOT)), errors)
        label = str(path.relative_to(ROOT))
        for key in ("name", "description", "developer_instructions"):
            if not isinstance(data.get(key), str) or not data[key]:
                errors.append(f"{label}: missing {key}")
        if data.get("name") != name:
            errors.append(f"{label}: name must be {name}")
        extra = set(data) - {"name", "description", "developer_instructions", "model", "model_reasoning_effort"}
        if extra:
            errors.append(f"{label}: keys {sorted(extra)} are ignored by Codex agent roles; remove them")
        if data.get("model") != agent.get("codex_model") or data.get("model_reasoning_effort") != agent.get(
            "codex_effort"
        ):
            errors.append(
                f"{label}: model and model_reasoning_effort must match the registry's codex_model and codex_effort"
            )
        instructions = data.get("developer_instructions", "")
        if "Remain read-only." not in instructions or CODEX_READ_ONLY_NOTICE not in instructions:
            errors.append(f"{label}: must carry the read-only instructions")
        if TURN_BUDGET_NOTICE not in instructions:
            errors.append(f"{label}: must carry the turn-budget wrap-up notice")
    specialists = json.loads(outputs[CODEX_SPECIALIST_TOOLS_PATH])
    if specialists != codex_specialist_tools(agents, policy):
        errors.append("codex/references/specialist-tools.json: differs from the policy and registry")
    mutating = policy_mutating_tools(policy)
    for name, tools in specialists.items():
        conditional = set(agents[name].get("conditional_tools", []))
        if any(tool in mutating and tool not in conditional for tool in tools):
            errors.append("codex/references/specialist-tools.json: a specialist allowlist holds a mutating tool")
    rules = outputs[CODEX_RULES_PATH]
    forbidden_patterns, prompt_patterns = codex_rule_patterns()
    for patterns, decision in ((forbidden_patterns, "forbidden"), (prompt_patterns, "prompt")):
        for pattern in patterns:
            for prefix in ([], ["rtk"]):
                if codex_rule_head([*prefix, *pattern], decision) not in rules:
                    errors.append(
                        f"codex/rules/b-agentic.rules: missing {decision} rule for {' '.join(prefix + pattern)}"
                    )
    for command in ("git pull", "git reset --hard", "sudo", "git push --force", "git push origin main"):
        if codex_rule_head(command.split(), "forbidden") not in rules:
            errors.append(f"codex/rules/b-agentic.rules: {command} must be forbidden")
    hooks = json.loads(outputs[CODEX_HOOKS_PATH])["hooks"]
    if set(hooks) != {"PreToolUse", "PostToolUse", "Stop"}:
        errors.append("codex/configs/hooks.template.json: expected PreToolUse, PostToolUse, and Stop hooks")
    for event, entries in hooks.items():
        for entry in entries:
            for hook in entry["hooks"]:
                if CODEX_HOOK_SCRIPT not in hook["command"] or hook["type"] != "command":
                    errors.append(f"codex/configs/hooks.template.json: {event} must run {CODEX_HOOK_SCRIPT}")
    pre = hooks["PreToolUse"][0]["matcher"]
    if not all(token in pre for token in ("apply_patch", "Bash", "mcp__")):
        errors.append("codex/configs/hooks.template.json: PreToolUse must cover apply_patch, Bash, and MCP tools")
    policy_path = CODEX_REFERENCES_DIR / "mcp_operations.yaml"
    effective_policy = json.loads(outputs[policy_path])
    if set(effective_policy["runtime_enforcement"]) != {"codex"}:
        errors.append(f"{policy_path.relative_to(ROOT)}: must describe Codex enforcement only")
    capabilities_path = CODEX_REFERENCES_DIR / "capabilities.yaml"
    capabilities = json.loads(outputs[capabilities_path])
    for capability in capabilities["capabilities"]:
        if capability["kind"] == "agent" and capability["agent"]["source"] != "codex/agents":
            errors.append(f"{capabilities_path.relative_to(ROOT)}: agent source must use Codex profiles")
    for path in (CODEX_KERNEL_PATH, CODEX_SKILLS_DIR / "b-clickup" / "SKILL.md", capabilities_path, policy_path):
        if "b-clickup-guard" in outputs[path]:
            errors.append(f"{path.relative_to(ROOT)}: the ClickUp image guard is not ported to Codex")
    return errors


def policy_mutating_tools(policy: dict[str, Any]) -> set[str]:
    return {
        mcp_tool_name(server, tool)
        for server, record in policy["servers"].items()
        for tool, class_name in record["tools"].items()
        if class_name != "read-only"
    }


def validate_codex_regressions(
    outputs: dict[Path, str], agents: dict[str, dict[str, Any]], policy: dict[str, Any]
) -> list[str]:
    """Each broken Codex asset must be rejected, so the structural checks cannot rot silently."""
    agent_path = CODEX_AGENTS_DIR / "b-planner.toml"
    cases = {
        "an agent role that sets sandbox_mode": {
            **outputs,
            agent_path: outputs[agent_path].replace("name = ", 'sandbox_mode = "read-only"\nname = ', 1),
        },
        "an agent role that drifts from the registry model": {
            **outputs,
            agent_path: outputs[agent_path].replace('model = "gpt-6.1-sol"', 'model = "gpt-6.1-terra"', 1),
        },
        "an agent role without the read-only notice": {
            **outputs,
            agent_path: outputs[agent_path].replace("Remain read-only.", "Be careful."),
        },
        "a managed server that does not prompt by default": {
            **outputs,
            CODEX_CONFIG_PATH: outputs[CODEX_CONFIG_PATH].replace(
                'default_tools_approval_mode = "prompt"', 'default_tools_approval_mode = "auto"', 1
            ),
        },
        "an unknown approval mode": {
            **outputs,
            CODEX_CONFIG_PATH: outputs[CODEX_CONFIG_PATH].replace(
                'approval_mode = "approve"', 'approval_mode = "bogus"', 1
            ),
        },
        "ClickUp create that does not prompt": {
            **outputs,
            CODEX_CLICKUP_PATH: outputs[CODEX_CLICKUP_PATH].replace(
                '[mcp_servers.clickup.tools.createTask]\napproval_mode = "prompt"',
                '[mcp_servers.clickup.tools.createTask]\napproval_mode = "approve"',
            ),
        },
        "a rule set without the sudo denial": {
            **outputs,
            CODEX_RULES_PATH: outputs[CODEX_RULES_PATH].replace('pattern = ["sudo"]', 'pattern = ["sudo-nothing"]'),
        },
        "a skill that recommends a slash command": {
            **outputs,
            CODEX_SKILLS_DIR / "b-commit" / "SKILL.md": outputs[CODEX_SKILLS_DIR / "b-commit" / "SKILL.md"]
            + "\nRecommend `/b-pr`.\n",
        },
        "a kernel that names a Claude-only tool": {
            **outputs,
            CODEX_KERNEL_PATH: outputs[CODEX_KERNEL_PATH] + "\nUse `AskUserQuestion`.\n",
        },
        "a hook template without the adapter": {
            **outputs,
            CODEX_HOOKS_PATH: outputs[CODEX_HOOKS_PATH].replace(CODEX_HOOK_SCRIPT, "other.mjs"),
        },
    }
    return [
        f"Codex regression: {label} must fail validation"
        for label, candidate in cases.items()
        if not validate_codex_outputs(candidate, agents, policy)
    ]


def validate_localization(outputs: dict[Path, str]) -> list[str]:
    """The claude runtime must reproduce its outputs exactly; other runtimes must shed Claude-only wording."""
    errors: list[str] = []
    prose = {path: text for path, text in outputs.items() if path.name == "SKILL.md" or path == KERNEL_TEMPLATE_PATH}
    for path, text in outputs.items():
        if localize(text, "claude") != text:
            errors.append(f"{path.relative_to(ROOT)}: claude runtime localization must be the identity")
    for runtime in RUNTIMES:
        if runtime == "claude":
            continue
        for path, text in prose.items():
            localized = localize(text, runtime)
            for forbidden in RUNTIMES[runtime].get("forbidden_terms", []):
                if forbidden in localized:
                    errors.append(f"{path.relative_to(ROOT)}: {runtime} rendering still contains {forbidden!r}")
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
        *validate_runtimes(),
    ]
    if errors:
        print("\n".join(errors), file=sys.stderr)
        return 1
    outputs = render_outputs(skills, agents, policy)
    errors = validate_codex_outputs(outputs, agents, policy)
    if errors:
        print("\n".join(errors), file=sys.stderr)
        return 1
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
        outputs = render_outputs(load_skills(), load_agents(), load_policy())
        errors = validate_localization(outputs)
        errors += validate_codex_regressions(outputs, load_agents(), load_policy())
        if errors:
            print("\n".join(errors), file=sys.stderr)
            return 1
        print("Runtime localization checks passed.")
    return sync_outputs(args.check)


if __name__ == "__main__":
    raise SystemExit(main())
