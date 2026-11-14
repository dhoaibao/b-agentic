#!/usr/bin/env python3
"""Render Claude Code and Pi delivery assets from b-agentic's canonical sources."""

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
RUNTIMES_PATH = ROOT / "references" / "runtimes.yaml"
CLAUDE_DIR = ROOT / "claude"
CLAUDE_AGENTS_DIR = CLAUDE_DIR / "agents"
CLAUDE_CONFIGS_DIR = CLAUDE_DIR / "configs"
SETTINGS_TEMPLATE_PATH = CLAUDE_CONFIGS_DIR / "settings.template.json"
SNAPSHOT_CLI_PATH = CLAUDE_DIR / "bin" / "b-candidate-snapshot.mjs"
RUN_CLI_PATH = CLAUDE_DIR / "bin" / "b_run.py"
ARTIFACTS_PATH = ROOT / "references" / "artifacts.yaml"
ARTIFACT_KINDS = ("spec", "plan", "qa", "followups")
PI_DIR = ROOT / "pi"
PI_CONFIGS_DIR = PI_DIR / "configs"
# Skill descriptions longer than this are not loaded by Pi (Agent Skills limit).
PI_DESCRIPTION_MAX = 1024
# A prompt line that starts with this marker is emitted only for the named runtime (marker removed).
RUNTIME_MARKER = re.compile(r"^<!-- runtime: ([a-z]+) --> ")

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

STATE_CLI_PATH = CLAUDE_DIR / "bin" / "b-state.mjs"
# What a skill is to a b-flow run: it completes a run phase, supplies evidence to one, stays outside
# every run, or sequences the run itself.
CONTRACT_ROLES = {"phase", "provider", "utility", "orchestrator"}
# Run phases only a phase skill completes; in `verify` the main session runs the plan checks itself.
SKILL_RUN_PHASES = ("clarify", "implement", "review", "fix", "qa", "commit")
# A phase skill here edits files, the index, or HEAD, so it can never run beside another.
TREE_CHANGING_PHASES = {"implement", "fix", "commit"}
PHASE_CONTRACTS_PLACEHOLDER = "{{phase_contracts}}"
# The kernel line of the routing entry: changes go through the orchestrator unless the user names a skill.
ENTRY_ROUTING_SUFFIX = ", as a quick or full run; a typed `/b-<name>` runs standalone"

EXECUTION_MODES = {"main", "subagent"}
PHASES = {"Decide", "Build", "Validate", "Ship"}
MANAGED_SUBAGENT_NAMES = {"b-planner", "b-researcher", "b-debugger", "b-auditor", "b-reviewer"}
# The one writer child of a b-flow run (ADR-015). It lives in its own registry map, so every
# read-only assertion about `agents` stays unconditional.
MANAGED_WORKER_NAMES = {"b-worker"}
WORKER_TOOLS = ("Read", "Grep", "Glob", "Edit", "Write", "Bash")
WORKER_FORBIDDEN_TOOLS = {"NotebookEdit", "Agent", "Task", "Skill", "AskUserQuestion"}
WORKER_FORBIDDEN_FIELDS = {"tools", "permission_mode", "isolation", "hooks", "skills", "background"}
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
# Tools a read-only specialist must never receive, whatever the registry says.
EDITING_TOOLS = tuple(CLAUDE_RUNTIME["editing_tools"])


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


def load_workers() -> dict[str, dict[str, Any]]:
    workers = load_registry().get("workers")
    if not isinstance(workers, dict):
        raise SystemExit(f"{SKILL_REGISTRY_PATH}: missing workers object")
    return workers


def load_policy() -> dict[str, Any]:
    return load_json_subset_yaml(MCP_OPERATIONS_PATH)


def load_capabilities() -> dict[str, Any]:
    return load_json_subset_yaml(CAPABILITIES_PATH)


def mcp_tool_name(server: str, tool: str) -> str:
    """Claude Code's name for an MCP tool: mcp__<server>__<tool>."""
    return CLAUDE_RUNTIME["mcp_tool_format"].format(server=server, tool=tool)


def apply_markers(text: str, runtime: str) -> str:
    """Keep each runtime-marked line only for its runtime, with the marker removed.

    Unmarked lines are shared. An unknown runtime name is an error, so a typo cannot silently drop a line.
    """
    kept: list[str] = []
    for line in text.split("\n"):
        match = RUNTIME_MARKER.match(line)
        if match is None:
            if "<!-- runtime:" in line:
                raise ValueError(f"malformed runtime marker (it must start the line): {line[:60]!r}")
            kept.append(line)
            continue
        if match.group(1) not in RUNTIMES:
            raise ValueError(f"unknown runtime {match.group(1)!r} in marker: {line[:60]!r}")
        if match.group(1) == runtime:
            kept.append(line[match.end() :])
    return "\n".join(kept)


def apply_glossary(text: str, runtime: str, hits: set[str] | None = None) -> str:
    """Ordered literal replacements that turn Claude Code wording into the runtime's own."""
    for entry in RUNTIMES[runtime].get("glossary", []):
        if entry["from"] in text:
            if hits is not None:
                hits.add(entry["from"])
            text = text.replace(entry["from"], entry["to"])
    return text


def apply_kernel_overrides(text: str, runtime: str) -> str:
    """Replace each kernel override once; an override that matches nothing or twice has drifted from the template."""
    for entry in RUNTIMES[runtime].get("kernel_overrides", []):
        count = text.count(entry["from"])
        if count != 1:
            raise ValueError(f"kernel override {entry['from']!r} matched {count} times, expected exactly 1")
        text = text.replace(entry["from"], entry["to"])
    return text


def tidy_blank_lines(text: str) -> str:
    return re.sub(r"\n{3,}", "\n\n", text)


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
        gate = skill.get("primary_gate")
        if gate is not None:
            if not isinstance(execution, dict) or execution.get("mode") != "subagent":
                errors.append(f"{label}.primary_gate: only subagent skills may define a primary gate")
            if not isinstance(gate, dict) or set(gate) != {"runtime", "label", "note"}:
                errors.append(f"{label}.primary_gate: expected runtime, label, and note")
            else:
                if gate["runtime"] not in RUNTIMES:
                    errors.append(f"{label}.primary_gate.runtime: expected one of {sorted(RUNTIMES)}")
                ensure_string(gate["label"], f"{label}.primary_gate.label", errors)
                ensure_string(gate["note"], f"{label}.primary_gate.note", errors)
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
            entry = routing.get("entry", False)
            if not isinstance(entry, bool):
                errors.append(f"{label}.routing.entry: expected boolean")
            if explicit and entry:
                errors.append(f"{label}.routing: a skill is the routing entry or explicit-request, not both")
            if explicit:
                if triggers is not None:
                    errors.append(f"{label}.routing.triggers: explicit-request skills must omit triggers")
            elif entry is True:
                if triggers is not None:
                    errors.append(f"{label}.routing.triggers: the routing entry must omit triggers")
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


def validate_workers(workers: dict[str, dict[str, Any]], agents: dict[str, dict[str, Any]]) -> list[str]:
    errors: list[str] = []
    if set(workers) != MANAGED_WORKER_NAMES:
        errors.append(f"skills/registry.yaml: workers must name {sorted(MANAGED_WORKER_NAMES)}")
    if set(workers) & set(agents):
        errors.append("skills/registry.yaml: a worker must not share a name with a read-only specialist")
    for name, worker in workers.items():
        label = f"workers.{name}"
        if not isinstance(worker, dict):
            errors.append(f"{label}: expected object")
            continue
        ensure_string(worker.get("description"), f"{label}.description", errors)
        model = ensure_string(worker.get("model"), f"{label}.model", errors)
        if model and model not in AGENT_MODELS:
            errors.append(f"{label}.model: expected one of {sorted(AGENT_MODELS)}")
        allowed_fields = {"description", "model"}
        if "effort" in worker:
            allowed_fields.add("effort")
            effort = ensure_string(worker["effort"], f"{label}.effort", errors)
            if effort and effort not in AGENT_EFFORTS:
                errors.append(f"{label}.effort: expected one of {sorted(AGENT_EFFORTS)}")
        if "max_turns" in worker:
            allowed_fields.add("max_turns")
            turns = worker["max_turns"]
            if isinstance(turns, bool) or not isinstance(turns, int) or turns < 1:
                errors.append(f"{label}.max_turns: expected positive integer")
        # The tools are the generator's: a registry entry cannot widen or narrow them.
        for field in sorted(WORKER_FORBIDDEN_FIELDS & set(worker)):
            errors.append(f"{label}.{field}: not a worker field; the generator owns the tool list and the frontmatter")
        if set(worker) - WORKER_FORBIDDEN_FIELDS != allowed_fields:
            errors.append(f"{label}: expected only {sorted(allowed_fields)}")
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


def validate_artifacts_schema() -> list[str]:
    """Keep references/artifacts.yaml, the run CLI, and the path rules in step (ADR-010)."""
    errors: list[str] = []
    label = ARTIFACTS_PATH.relative_to(ROOT)
    try:
        schema = json.loads(ARTIFACTS_PATH.read_text())
    except (OSError, ValueError) as exc:
        return [f"{label}: unreadable ({exc})"]
    if schema.get("version") != 1:
        errors.append(f"{label}: version must be 1")
    kinds = schema.get("kinds", {})
    if set(kinds) != set(ARTIFACT_KINDS):
        errors.append(f"{label}: kinds must be exactly {list(ARTIFACT_KINDS)}")
    enums = schema.get("enums", {})
    run_files = schema.get("run_files", [])
    for required in ("state.json", "artifacts.json", "lock", "mutex"):
        if required not in run_files:
            errors.append(f"{label}: run_files must include {required}")

    def walk(spec: Any, where: str) -> None:
        if not isinstance(spec, dict) or spec.get("type") not in {"line", "text", "id", "enum", "list", "object"}:
            errors.append(f"{label}: {where} has an unknown field type")
            return
        if spec["type"] == "enum" and not (spec.get("values") or spec.get("enum") in enums):
            errors.append(f"{label}: {where} names an unknown enum")
        if spec["type"] == "id":
            try:
                re.compile(spec.get("pattern", ""))
            except re.error:
                errors.append(f"{label}: {where} has an invalid pattern")
        if spec["type"] == "list":
            walk(spec.get("items"), f"{where}[]")
        if spec["type"] == "object":
            for name, sub in spec.get("fields", {}).items():
                walk(sub, f"{where}.{name}")

    for kind in ARTIFACT_KINDS:
        entry = kinds.get(kind)
        if not isinstance(entry, dict):
            continue
        if entry.get("file") not in run_files:
            errors.append(f"{label}: {kind}.file must be listed in run_files")
        if not entry.get("phases") or not entry.get("example"):
            errors.append(f"{label}: {kind} needs phases and an example")
        for name, sub in entry.get("fields", {}).items():
            walk(sub, f"{kind}.{name}")
    if not RUN_CLI_PATH.is_file():
        return [*errors, f"{RUN_CLI_PATH.relative_to(ROOT)}: missing run artifact CLI"]
    text = RUN_CLI_PATH.read_text()
    block = re.search(r"PROTECTED_RULES = \[(.*?)\n\]", text, re.S)
    mirror = re.findall(r'\("([^"]+)", "(allow|deny)"\)', block.group(1)) if block else []
    policy = [(pattern, action) for pattern, action in PATH_RULES.items() if pattern != "*"]
    if mirror != policy:
        errors.append(f"{RUN_CLI_PATH.relative_to(ROOT)}: PROTECTED_RULES must match the generated path rules")
    return errors


def packet_phases() -> tuple[str, ...]:
    """The run phases `b_run.py handoff` renders a packet for, read from the CLI itself."""
    block = re.search(r"^HANDOFF_PHASES = \((.*?)\)$", RUN_CLI_PATH.read_text(), re.M)
    return tuple(re.findall(r'"([a-z]+)"', block.group(1))) if block else ()


def state_phases() -> tuple[str, ...]:
    block = re.search(r"export const PHASES = \[(.*?)\];", STATE_CLI_PATH.read_text(), re.S)
    return tuple(re.findall(r'"([a-z]+)"', block.group(1))) if block else ()


def validate_contracts(skills: list[dict[str, Any]]) -> list[str]:
    """Every skill says what it is to a run, in phases the run CLIs know, and every phase has a skill."""
    errors: list[str] = []
    packets = packet_phases()
    if not packets or not set(packets) <= set(state_phases()):
        errors.append(f"{RUN_CLI_PATH.relative_to(ROOT)}: HANDOFF_PHASES must be run phases of b-state.mjs")
    covered: set[str] = set()
    orchestrators: list[str] = []
    for skill in skills:
        label = f"skills.{skill.get('name')}.contract"
        contract = skill.get("contract")
        if not isinstance(contract, dict) or contract.get("role") not in CONTRACT_ROLES:
            errors.append(f"{label}.role: expected one of {sorted(CONTRACT_ROLES)}")
            continue
        role = contract["role"]
        if role in ("utility", "orchestrator"):
            if set(contract) != {"role"}:
                errors.append(f"{label}: a {role} declares only its role")
            if role == "orchestrator":
                orchestrators.append(skill.get("name"))
            continue
        if set(contract) != {"role", "phases", "evidence", "parallel_safe"}:
            errors.append(f"{label}: expected role, phases, evidence, and parallel_safe")
            continue
        phases = contract["phases"]
        if (
            not isinstance(phases, list)
            or not phases
            or not all(isinstance(phase, str) for phase in phases)
            or len(set(phases)) != len(phases)
            or not set(phases) <= set(packets)
        ):
            errors.append(f"{label}.phases: expected distinct run phases from {list(packets)}")
            continue
        ensure_string(contract["evidence"], f"{label}.evidence", errors)
        if not isinstance(contract["parallel_safe"], bool):
            errors.append(f"{label}.parallel_safe: expected boolean")
        elif role == "phase":
            covered.update(phases)
            if contract["parallel_safe"] and TREE_CHANGING_PHASES & set(phases):
                errors.append(f"{label}.parallel_safe: a skill for {sorted(TREE_CHANGING_PHASES)} changes the tree")
    if orchestrators != ["b-flow"]:
        errors.append("skills/registry.yaml: b-flow, and only b-flow, is the orchestrator")
    elif PHASE_CONTRACTS_PLACEHOLDER not in (ROOT / "skills" / "b-flow" / "prompt.md").read_text():
        errors.append(f"skills/b-flow/prompt.md: missing {PHASE_CONTRACTS_PLACEHOLDER}")
    missing = [phase for phase in SKILL_RUN_PHASES if phase not in covered]
    if missing:
        errors.append(f"skills/registry.yaml: no phase skill for run phase(s) {missing}")
    # Change requests enter a run through the orchestrator, and its routing line names exactly the
    # skills whose work that is: the phase skills of `implement`.
    entries = [skill for skill in skills if isinstance(skill.get("routing"), dict) and skill["routing"].get("entry")]
    if [skill.get("name") for skill in entries] != orchestrators:
        errors.append("skills/registry.yaml: the orchestrator, and only the orchestrator, is the routing entry")
    else:
        implementers = {
            skill.get("name")
            for skill in skills
            if isinstance(skill.get("contract"), dict)
            and skill["contract"].get("role") == "phase"
            and "implement" in (skill["contract"].get("phases") or [])
        }
        for skill in entries:
            if set(re.findall(r"b-[a-z0-9-]+", str(skill["routing"].get("intent")))) != implementers:
                errors.append(
                    f"skills.{skill.get('name')}.routing.intent: must name exactly the implement-phase skills"
                    f" {sorted(implementers)}"
                )
    return errors


def render_phase_contracts(skills: list[dict[str, Any]]) -> str:
    """The orchestrator's phase table: who works in each run phase, its packet, and what each skill returns."""

    def names(phase: str, role: str) -> str:
        return ", ".join(
            f"`{skill['name']}`"
            for skill in skills
            if skill["contract"]["role"] == role and phase in skill["contract"]["phases"]
        )

    lines = ["| Run phase | Phase skills | Evidence providers | Packet |", "| --- | --- | --- | --- |"]
    for phase in packet_phases():
        lines.append(
            f"| {phase} | {names(phase, 'phase') or 'main session'} | {names(phase, 'provider') or 'none'}"
            f" | `b_run.py handoff {phase}` |"
        )
    # Skills that return the same evidence share one line.
    returned: dict[str, list[str]] = {}
    for skill in skills:
        if skill["contract"]["role"] in ("phase", "provider"):
            returned.setdefault(skill["contract"]["evidence"], []).append(f"`{skill['name']}`")
    lines += ["", "What each skill returns to the run:", ""]
    lines += [f"- {', '.join(names_)}: {evidence}." for evidence, names_ in returned.items()]
    return "\n".join(lines)


def validate_optional_components(skills: list[dict[str, Any]], policy: dict[str, Any]) -> list[str]:
    """Optional components name real main-session skills and policy servers, never overlap, and can be
    filtered out of both kernels (exactly one routing line per skill)."""
    sys.path.insert(0, str(ROOT / "tooling" / "install"))
    try:
        import optional_components
    finally:
        sys.path.pop(0)
    try:
        components = optional_components.load(ROOT)
    except ValueError as exc:
        return [str(exc)]
    errors: list[str] = []
    by_name = {skill.get("name"): skill for skill in skills if isinstance(skill, dict)}
    servers = policy.get("servers", {})
    seen_skills: dict[str, str] = {}
    seen_servers: dict[str, str] = {}
    for key, component in components.items():
        label = f"optional_components.{key}"
        if not component.get("skills") and not component.get("mcp_servers"):
            errors.append(f"{label}: expected at least one skill or MCP server")
        for name in component.get("skills", []):
            skill = by_name.get(name)
            if skill is None:
                errors.append(f"{label}: unknown skill {name!r}")
            elif skill.get("execution", {}).get("mode") != "main":
                errors.append(f"{label}: {name} must run in the main session (a delegated skill needs its agent)")
            if name in seen_skills:
                errors.append(f"{label}: skill {name} is also in optional_components.{seen_skills[name]}")
            seen_skills[name] = key
        for name in component.get("mcp_servers", []):
            if name not in servers:
                errors.append(f"{label}: MCP server {name!r} is not in the MCP operations policy")
            if name in seen_servers:
                errors.append(f"{label}: server {name} is also in optional_components.{seen_servers[name]}")
            seen_servers[name] = key
    for key, component in components.items():
        try:
            optional_components.filter_kernel(KERNEL_TEMPLATE_PATH.read_text(), set(component.get("skills", [])))
        except (OSError, ValueError) as exc:
            errors.append(f"optional_components.{key}: {KERNEL_TEMPLATE_PATH.relative_to(ROOT)}: {exc}")
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
        runtimes = capability.get("runtimes")
        if runtimes is not None and (
            not isinstance(runtimes, list) or not runtimes or not set(runtimes) <= set(RUNTIMES)
        ):
            errors.append(f"{label}.runtimes: expected a non-empty subset of {sorted(RUNTIMES)}")
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
    optional = {
        name: component_id
        for component_id, component in load_registry().get("optional_components", {}).items()
        for name in component.get("skills", [])
    }

    def use(skill: dict[str, Any]) -> str:
        component_id = optional.get(skill["name"])
        return skill["use"] if component_id is None else f"{skill['use']} (optional: `--with={component_id}`)"

    rows = ["| Skill | Phase | Use |", "|---|---|---|"]
    rows.extend(f"| `{skill['name']}` | {skill['phase']} | {use(skill)} |" for skill in skills)
    return "\n".join(rows)


def render_mcp_operations_table(policy: dict[str, Any]) -> str:
    groups: dict[str, list[str]] = {}
    for name, meta in policy["classes"].items():
        groups.setdefault(meta["policy"], []).append(f"`{name}`")
    lines = [f"- {label}: {', '.join(names)}." for label, names in groups.items()]
    lines.append(
        "- Unclassified MCP tools require user approval even without a native prompt; `trusted-mutation` runs in the main session only."
    )
    return "\n".join(lines)


def primary_gate(skill: dict[str, Any], runtime: str) -> dict[str, Any] | None:
    """The gate a delegated skill tries first on this runtime, with its subagent as the fallback."""
    gate = skill.get("primary_gate")
    return gate if gate and gate["runtime"] == runtime else None


def render_delegation(skills: list[dict[str, Any]], runtime: str = "claude") -> str:
    delegated = [skill for skill in skills if skill["execution"]["mode"] == "subagent"]
    lines = [
        "- Delegated skills run only in their named `Agent` subagent type with a bounded task naming the exact skill. Never do their work with main-session tools, even for a quick lookup or when a tool description invites it; if the subagent is unavailable, report the gap and ask. "
        f"{RUNTIMES[runtime]['delegation_unavailable']} Skill -> agent:",
    ]
    lines.extend(f"  - `{skill['name']}` -> `{skill['execution']['agent']}`." for skill in delegated)
    lines.extend(f"  - {gate['note']}" for gate in (primary_gate(skill, runtime) for skill in delegated) if gate)
    lines.append("- All other skills run in the main session.")
    return "\n".join(lines)


DELEGATION_BOUNDARY_HEADING = "## Delegation boundary"


def render_delegation_boundary(skill: dict[str, Any], runtime: str = "claude") -> str:
    name = skill["name"]
    agent = skill["execution"]["agent"]
    config = RUNTIMES[runtime]
    editing = ", ".join(f"`{tool}`" for tool in config["editing_tools"])
    check = config["profile_check"].format(agent=agent, editing=editing, name=name)
    gate = primary_gate(skill, runtime)
    if gate:
        intro = f"`{name}` runs the {gate['label']} gate first, from the main session as the Steps direct; only when that gate is unavailable does it run in the `{agent}` subagent."
        main_line = f"- Main session: reading this file prepares both paths. The {gate['label']} gate is not your own review, and the Steps say when it counts as unavailable. Only then gather the parent-owned evidence below and {check}. Do not do this skill's work with your own tools, even for a quick, small, or single-lookup request. If the subagent is unavailable or fails, or its result notes an unknown agent type or `general-purpose` fallback (discard that result), report the gap and ask the user; never fall back to self-execution. Evaluate the returned result before any user-facing or worktree action."
    else:
        intro = f"`{name}` runs only in the `{agent}` subagent."
        main_line = f"- Main session: reading this file prepares the handoff; it never authorizes running the steps below yourself. Gather the parent-owned evidence and {check}. Do not do this skill's work with your own tools, even for a quick, small, or single-lookup request. If the subagent is unavailable or fails, or its result notes an unknown agent type or `general-purpose` fallback (discard that result), report the gap and ask the user; never fall back to self-execution. Evaluate the returned result before any user-facing or worktree action."
    lines = [
        DELEGATION_BOUNDARY_HEADING,
        "",
        intro,
        "",
        main_line,
        f"- `{agent}` child: execute the {'reviewer steps below only (never the ' + gate['label'] + ' gate)' if gate else 'steps below'} read-only, return this skill's Output format to the main session, and do not delegate again.",
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
        if skill["routing"].get("entry"):
            suffix = ENTRY_ROUTING_SUFFIX
        lines.append(f"- {skill['routing']['intent']} -> `{skill['name']}`{suffix}.")
    return "\n".join(lines)


def fold_yaml(key: str, value: str) -> list[str]:
    wrapper = textwrap.TextWrapper(width=74, initial_indent="  ", subsequent_indent="  ", break_long_words=False)
    return [f"{key}: >", *wrapper.fill(value).splitlines()]


def render_skill_file(skill: dict[str, Any], runtime: str = "claude", hits: set[str] | None = None) -> str:
    name = skill["name"]
    description = skill["prompt"]["description"]
    triggers = skill["routing"].get("triggers")
    if triggers:
        description += f" Routing signals: {', '.join(triggers)}."
    body = (ROOT / "skills" / name / "prompt.md").read_text().rstrip()
    body = apply_markers(body, runtime)
    body = body.replace("{{skill_support_path}}", "<skill-dir>")
    if PHASE_CONTRACTS_PLACEHOLDER in body:
        body = body.replace(PHASE_CONTRACTS_PLACEHOLDER, render_phase_contracts(load_skills()))
    execution = skill["execution"]
    if execution["mode"] == "subagent":
        head, sep, rest = body.partition("\n## ")
        if not sep:
            raise SystemExit(f"skills/{name}/prompt.md: expected a '## ' section to place the delegation boundary")
        body = f"{head}\n{render_delegation_boundary(skill, runtime)}\n\n## {rest}"
        gate = primary_gate(skill, runtime)
        if gate:
            description += (
                f" Runs the {gate['label']} gate first from the main session and, only when it is unavailable,"
                f" delegates to the `{execution['agent']}` subagent; the main session never executes the review itself."
            )
        else:
            description += f" Delegated: runs only in the `{execution['agent']}` subagent; the main session never executes it itself."
    if runtime != "claude":
        body = tidy_blank_lines(apply_glossary(body, runtime, hits))
    lines = ["---", f"name: {name}"]
    lines.extend(fold_yaml("description", description))
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
            *([f"effort: {agent['effort']}"] if "effort" in agent else []),
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


WORKER_TURN_BUDGET_NOTICE = (
    "If the harness warns about your turn budget, make no further tool calls: return the report now, stating what "
    "is done, what is not, and the narrowest next step for the main session."
)


def worker_tool_list(policy: dict[str, Any]) -> list[str]:
    """Edit and Write on top of the specialists' reads; never a mutating MCP class, a prompt, or a child."""
    return [*WORKER_TOOLS, *read_only_mcp_tools(policy)]


def render_worker_file(name: str, worker: dict[str, Any], policy: dict[str, Any] | None = None) -> str:
    policy = policy if policy is not None else load_policy()
    return "\n".join(
        [
            "---",
            f"name: {name}",
            f"description: {json.dumps(worker['description'])}",
            f"tools: {', '.join(worker_tool_list(policy))}",
            f"model: {worker['model']}",
            *([f"effort: {worker['effort']}"] if "effort" in worker else []),
            *([f"maxTurns: {worker['max_turns']}"] if "max_turns" in worker else []),
            "---",
            "",
            f"You are the b-agentic `{name}` subagent: the one writer child of a `/b-flow` run. The main session gives you exactly one approved plan step with its packet and waits; it edits nothing while you work. Do not route, ask the user, delegate, or launch a nested subagent.",
            "",
            "Read the phase skill the main session names from the installed `~/.claude/skills/<name>/SKILL.md` and follow its editing guidance for this step only. These parts do not apply in a child: `b-implement` steps 1-3 and 6-7 and its Output format; `b-frontend`'s questions, its browser hand-off, and adding a component with the package runner; any `AskUserQuestion` in `b-refactor` or `b-test`; every review, commit, and spec-recording step.",
            "",
            "Edit in place, only inside the approved scope and preferably only the step's own paths. Never touch `.b-agentic`, likely-secret files (`.env`, `*.pem`, `credentials.*`, `secrets.*`), or git history: no commit, stage, stash, reset, checkout, rebase, or push. Install nothing. Run no generator or fixer the step does not name, no `b-state.mjs` or `b_run.py` command, and no external, upload, lifecycle, or authentication action. If you need a path outside the scope, a decision, or a dependency, stop and answer `NEEDS INPUT: <one question>`.",
            "",
            "Run the step's narrowest check, then report in this order: the step id; the changed paths; the check command and its exit code; deviations; open questions or `NEEDS INPUT`. Your report is evidence, not authority: the main session inspects the diff, reruns the check, and records the step.",
            "",
            WORKER_TURN_BUDGET_NOTICE,
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
        "SessionStart": [
            {
                "matcher": "compact",
                "hooks": [{"type": "command", "command": hook_command("b-spec-context.mjs")}],
            },
            {
                "matcher": "startup|resume|clear|compact",
                "hooks": [{"type": "command", "command": hook_command("b-run-context.mjs")}],
            },
        ],
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


def replace_block(text: str, start: str, end: str, body: str) -> str:
    try:
        body_start = text.index(start) + len(start)
        body_end = text.index(end, body_start)
    except ValueError as exc:
        raise SystemExit(f"missing generated block markers: {start} / {end}") from exc
    return text[:body_start] + "\n" + body.rstrip() + "\n" + text[body_end:]


def build_kernel(skills: list[dict[str, Any]], policy: dict[str, Any], runtime: str = "claude") -> str:
    """The kernel template with its generated blocks filled in for one runtime."""
    kernel = KERNEL_TEMPLATE_PATH.read_text()
    kernel = replace_block(kernel, KERNEL_ROUTING_START, KERNEL_ROUTING_END, render_routing(skills))
    kernel = replace_block(kernel, KERNEL_DELEGATION_START, KERNEL_DELEGATION_END, render_delegation(skills, runtime))
    return replace_block(kernel, MCP_OPERATIONS_START, MCP_OPERATIONS_END, render_mcp_operations_table(policy))


def render_pi_kernel(skills: list[dict[str, Any]], policy: dict[str, Any], hits: set[str] | None = None) -> str:
    kernel = apply_kernel_overrides(build_kernel(skills, policy, "pi"), "pi")
    return apply_glossary(kernel, "pi", hits)


def render_pi_prompt(skill: dict[str, Any]) -> str:
    """A thin `/b-<name>` prompt template that points at the installed Pi skill."""
    name = skill["name"]
    first_sentence = skill["prompt"]["description"].split(". ")[0].rstrip(".") + "."
    lines = ["---", f"description: {json.dumps(first_sentence, ensure_ascii=False)}"]
    if skill.get("argument_hint"):
        lines.append(f"argument-hint: {json.dumps(skill['argument_hint'], ensure_ascii=False)}")
    lines.extend(
        [
            "---",
            "",
            f"Read the installed `{RUNTIMES['pi']['config_dir']}/skills/{name}/SKILL.md` and follow it for this request.",
            "",
            "Arguments: $ARGUMENTS",
            "",
            "<!-- Generated from skills/registry.yaml. Edit that source, not this file. -->",
            "",
        ]
    )
    return "\n".join(lines)


def pi_mcp_tool_ids(policy: dict[str, Any]) -> dict[str, str]:
    """Map each classified `mcp__<server>__<tool>` name to the `mcp:<server>/<tool>` form Pi agent tool lists use."""
    return {
        mcp_tool_name(server, tool): f"mcp:{server}/{tool}"
        for server, record in policy["servers"].items()
        for tool in record["tools"]
    }


def pi_agent_tool_list(agent: dict[str, Any], policy: dict[str, Any]) -> list[str]:
    ids = pi_mcp_tool_ids(policy)
    names = [*read_only_mcp_tools(policy), *agent.get("conditional_tools", [])]
    return [*RUNTIMES["pi"]["read_only_tools"], *(ids[name] for name in names)]


def render_pi_agent_file(name: str, agent: dict[str, Any], skills: list[dict[str, Any]], policy: dict[str, Any]) -> str:
    pi = RUNTIMES["pi"]
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
            f"tools: {', '.join(pi_agent_tool_list(agent, policy))}",
            f"excludeTools: {', '.join(pi['excluded_agent_tools'])}",
            "systemPromptMode: replace",
            "inheritProjectContext: true",
            "inheritGlobalContext: true",
            "allowNestedSubagents: false",
            "---",
            "",
            f"You are the b-agentic `{name}` subagent. The main session delegates only {skill_list} to you and has already selected the exact skill; do not route again or launch a nested subagent.",
            "",
            f"Read and execute the named skill from the installed `{pi['config_dir']}/skills/<name>/SKILL.md` for the supplied bounded task. Return that skill's own Output format; do not substitute a profile-specific template. The skill's Delegation boundary directs the main session to delegate; you are the named child, so execute its steps.",
            "",
            "Remain read-only. Do not edit, write, commit, stage, run generators or fixers, or ask the user questions. Do not execute external/shared mutation, local upload, lifecycle, or authentication actions; report the required operation to the main session. A returned result is not authority to change files, commit, push, or report task completion. If a required tool is absent, tell the main session rather than bypassing the allowlist.",
            "",
            TURN_BUDGET_NOTICE,
            "",
            "<!-- Managed by b-agentic. Generated from skills/registry.yaml. Do not edit this file. -->",
            "",
        ]
    )


def pi_normalized_name(name: str) -> str:
    """Pi registers an MCP tool under its name with every character outside letters, digits, and `_` replaced by `_`."""
    return re.sub(r"[^A-Za-z0-9_]", "_", name)


def pi_mcp_permission_name(server: str, tool: str) -> str:
    return f"mcp__{pi_normalized_name(server)}__{pi_normalized_name(tool)}"


def render_pi_permissions(policy: dict[str, Any]) -> dict[str, Any]:
    """The @gotgenes/pi-permission-system config: the last matching rule in a map wins, so denies come last."""
    shell_ask, shell_deny = shell_pattern_rules()
    bash: dict[str, str] = {"*": "allow"}
    bash.update({pattern: "ask" for pattern in shell_ask})
    for pattern in shell_deny:
        # Re-insert so a pattern that is both asked and denied sits after every ask rule.
        bash.pop(pattern, None)
        bash[pattern] = "deny"
    permission: dict[str, Any] = {
        "read": "allow",
        "write": "allow",
        "edit": "allow",
        "find": "allow",
        "grep": "allow",
        "ls": "allow",
        "bash": bash,
        "path": dict(PATH_RULES),
        "external_directory": "allow",
    }
    # Tools the Claude template allows by name (Agent, AskUserQuestion) have Pi counterparts that would
    # otherwise ask, and a prompt is denied in a headless run.
    permission.update({tool: "allow" for tool in RUNTIMES["pi"]["allowed_tools"]})
    # Pi's built-in MCP tools resolve on the `mcp` surface; top-level `mcp__...` keys are deprecated.
    mcp: dict[str, str] = {"*": "ask"}
    for server, record in policy["servers"].items():
        for tool, class_name in record["tools"].items():
            mcp[pi_mcp_permission_name(server, tool)] = policy["classes"][class_name]["native_permission"]
    permission["mcp"] = mcp
    return {"yoloMode": False, "permission": permission}


def render_pi_mcp() -> dict[str, Any]:
    """Built-in MCP entries: the Claude template plus the exposure that lets the model call each server's tools."""
    config = json.loads((CLAUDE_CONFIGS_DIR / "mcp.base.json").read_text())
    exposure = RUNTIMES["pi"]["mcp_exposure"]
    for name, entry in config["mcpServers"].items():
        entry["exposure"] = "direct" if name in exposure["direct"] else exposure["default"]
    return config


def render_pi_settings_packages() -> dict[str, Any]:
    return {"packages": list(RUNTIMES["pi"]["packages"])}


def render_pi_outputs(
    skills: list[dict[str, Any]],
    agents: dict[str, dict[str, Any]],
    policy: dict[str, Any],
    hits: set[str] | None = None,
) -> dict[Path, str]:
    outputs: dict[Path, str] = {
        PI_DIR / "kernel.md": render_pi_kernel(skills, policy, hits),
        PI_CONFIGS_DIR / "permission.json": json.dumps(render_pi_permissions(policy), indent=2) + "\n",
        PI_CONFIGS_DIR / "mcp.base.json": json.dumps(render_pi_mcp(), indent=2) + "\n",
        PI_CONFIGS_DIR / "settings.packages.json": json.dumps(render_pi_settings_packages(), indent=2) + "\n",
    }
    for skill in skills:
        outputs[PI_DIR / "skills" / skill["name"] / "SKILL.md"] = render_skill_file(skill, "pi", hits)
        outputs[PI_DIR / "prompts" / f"{skill['name']}.md"] = render_pi_prompt(skill)
    for name, agent in agents.items():
        outputs[PI_DIR / "agents" / f"{name}.md"] = render_pi_agent_file(name, agent, skills, policy)
    return outputs


def forbidden_hits(text: str, runtime: str) -> list[str]:
    return [token for token in RUNTIMES[runtime].get("forbidden_tokens", []) if token in text]


def validate_pi_agent_tools(name: str, tools: list[str]) -> list[str]:
    pi = RUNTIMES["pi"]
    errors = [
        f"pi agent {name}: tool {tool!r} is not allowed on a read-only specialist"
        for tool in tools
        if tool in pi["excluded_agent_tools"]
    ]
    if any(tool.startswith("mcp:notion/") for tool in tools):
        errors.append(f"pi agent {name}: must not receive private Notion workspace tools")
    return errors


def pi_output_errors(
    skills: list[dict[str, Any]], agents: dict[str, dict[str, Any]], policy: dict[str, Any]
) -> list[str]:
    """Checks on the rendered Pi outputs: leaked Claude vocabulary, read-only agents, budgets, stale glossary."""
    errors: list[str] = []
    hits: set[str] = set()
    try:
        outputs = render_pi_outputs(skills, agents, policy, hits)
    except ValueError as exc:
        return [f"pi outputs: {exc}"]
    for path, text in outputs.items():
        relative = path.relative_to(ROOT)
        if relative.parts[:2] != ("pi", "configs"):
            errors.extend(
                f"{relative}: contains forbidden Claude Code token {token!r}" for token in forbidden_hits(text, "pi")
            )
        if "<!-- runtime:" in text:
            errors.append(f"{relative}: unresolved runtime marker")
    for entry in RUNTIMES["pi"]["glossary"]:
        if entry["from"] not in hits:
            errors.append(f"runtimes.pi.glossary: entry {entry['from']!r} matched nothing; remove or update it")
    names = [
        pi_mcp_permission_name(server, tool) for server, record in policy["servers"].items() for tool in record["tools"]
    ]
    if len(names) != len(set(names)):
        errors.append("pi permission: two MCP tools share one normalized name (Pi would hash-suffix them)")
    kernel = outputs[PI_DIR / "kernel.md"]
    if "Pi Workflow Kernel" not in kernel:
        errors.append("pi/kernel.md: missing the Pi kernel title")
    if len(kernel.encode()) > MAX_KERNEL_BYTES:
        errors.append(f"pi/kernel.md: exceeds {MAX_KERNEL_BYTES:,} byte kernel budget")
    if len(kernel.splitlines()) > MAX_KERNEL_LINES:
        errors.append(f"pi/kernel.md: exceeds {MAX_KERNEL_LINES} line kernel budget")
    for skill in skills:
        text = outputs[PI_DIR / "skills" / skill["name"] / "SKILL.md"]
        match = re.search(r"^description: >\n((?:  .*\n)+)", text, re.MULTILINE)
        description = " ".join(line.strip() for line in match.group(1).splitlines()) if match else ""
        if not description or len(description) > PI_DESCRIPTION_MAX:
            errors.append(f"pi/skills/{skill['name']}: description must be 1-{PI_DESCRIPTION_MAX} characters")
    for name, agent in agents.items():
        errors.extend(validate_pi_agent_tools(name, pi_agent_tool_list(agent, policy)))
    review = outputs[PI_DIR / "skills" / "b-review" / "SKILL.md"]
    if "b-reviewer" not in review:
        errors.append("pi/skills/b-review: must use the b-reviewer subagent gate")
    return errors


def render_outputs(
    skills: list[dict[str, Any]],
    agents: dict[str, dict[str, Any]],
    policy: dict[str, Any],
    workers: dict[str, dict[str, Any]],
) -> dict[Path, str]:
    readme = ROOT / "README.md"
    kernel = build_kernel(skills, policy)
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
    # Claude Code only: Pi has no writer child (ADR-015).
    for name, worker in workers.items():
        outputs[CLAUDE_AGENTS_DIR / f"{name}.md"] = render_worker_file(name, worker, policy)
    outputs.update(render_pi_outputs(skills, agents, policy))
    return outputs


def validate_worker_regressions(
    agents: dict[str, dict[str, Any]], policy: dict[str, Any], workers: dict[str, dict[str, Any]]
) -> list[str]:
    """The writer child is the one exception to read-only children, and only as the generator renders it."""
    errors: list[str] = []
    if validate_workers(workers, agents):
        errors.append("worker regression: the registry's own workers must pass")

    def worker_errors(change: Any) -> list[str]:
        candidate = json.loads(json.dumps(workers))
        change(candidate)
        return validate_workers(candidate, agents)

    cases = (
        (lambda w: w["b-worker"].pop("model"), "a missing model"),
        (lambda w: w["b-worker"].update(model="gpt-9"), "an unknown model alias"),
        (lambda w: w["b-worker"].update(effort="extreme"), "an unknown effort"),
        (lambda w: w["b-worker"].update(max_turns=0), "a non-positive max_turns"),
        (lambda w: w["b-worker"].update(tools=["NotebookEdit"]), "a registry tool list"),
        (lambda w: w["b-worker"].update(permission_mode="acceptEdits"), "a permission_mode"),
        (lambda w: w["b-worker"].update(isolation="worktree"), "an isolation field"),
        (lambda w: w["b-worker"].update(hooks={}), "a hooks field"),
        (lambda w: w["b-worker"].update(skills=["b-flow"]), "a skills field"),
        (lambda w: w["b-worker"].update(background=True), "a background field"),
        (lambda w: w["b-worker"].update(color="red"), "an unknown field"),
        (lambda w: w.update({"b-worker-2": dict(w["b-worker"])}), "a second worker"),
        (lambda w: w.update({"b-planner": w.pop("b-worker")}), "a worker named like a specialist"),
        (lambda w: w.clear(), "no worker"),
    )
    for change, why in cases:
        if not worker_errors(change):
            errors.append(f"worker regression: {why} must fail")
    if not validate_workers({**workers, **agents}, agents):
        errors.append("worker regression: specialists listed as workers must fail")
    invalid_agent_tools = json.loads(json.dumps(agents))
    invalid_agent_tools["b-researcher"]["conditional_tools"].append("Edit")
    if not validate_agent_tools(invalid_agent_tools, policy):
        errors.append("agent regression: a read-only specialist given Edit must still fail")
    for name, worker in workers.items():
        rendered = render_worker_file(name, worker, policy)
        head, _, _body = rendered.partition("\n---\n")
        frontmatter = dict(line.split(": ", 1) for line in head.removeprefix("---\n").splitlines() if ": " in line)
        tools = [tool.strip() for tool in frontmatter.get("tools", "").split(",")]
        if tools[: len(WORKER_TOOLS)] != list(WORKER_TOOLS) or tools[len(WORKER_TOOLS) :] != read_only_mcp_tools(
            policy
        ):
            errors.append(f"worker regression: {name} tools must be the worker set plus the read-only MCP tools")
        if WORKER_FORBIDDEN_TOOLS & set(tools) or any(tool.startswith("mcp__notion__") for tool in tools):
            errors.append(f"worker regression: {name} must not receive a prompt, delegation, notebook, or Notion tool")
        if set(frontmatter) - {"name", "description", "tools", "model", "effort", "maxTurns"}:
            errors.append(
                f"worker regression: {name} frontmatter must carry only name, description, tools, model, effort"
            )
        if WORKER_TURN_BUDGET_NOTICE not in rendered:
            errors.append(f"worker regression: {name} profile must carry the turn-budget wrap-up notice")
        for clause in ("NEEDS INPUT", ".b-agentic", "git history", "no `b-state.mjs` or `b_run.py` command"):
            if clause not in rendered:
                errors.append(f"worker regression: {name} profile must state {clause!r}")
        if name in MANAGED_SUBAGENT_NAMES:
            errors.append(f"worker regression: {name} must not be a read-only specialist")
    return errors


def validate_regressions(
    skills: list[dict[str, Any]],
    agents: dict[str, dict[str, Any]],
    capabilities: dict[str, Any],
    policy: dict[str, Any],
    workers: dict[str, dict[str, Any]],
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

    def contract_errors(name: str, change: dict[str, Any]) -> list[str]:
        candidate = json.loads(json.dumps(skills))
        next(skill for skill in candidate if skill["name"] == name)["contract"].update(change)
        return validate_contracts(candidate)

    if validate_contracts(skills):
        errors.append("contract regression: the registry's own contracts must pass")
    for name, change, why in (
        ("b-plan", {"role": "worker"}, "an unknown role"),
        ("b-plan", {"phases": ["planning"]}, "a phase the run CLIs do not know"),
        ("b-plan", {"phases": []}, "a phase skill without phases"),
        ("b-review", {"phases": ["qa"]}, "a run phase left without a phase skill"),
        ("b-implement", {"parallel_safe": True}, "a tree-changing skill marked parallel-safe"),
        ("b-qa", {"evidence": ""}, "a phase skill without evidence"),
        ("b-pr", {"phases": ["commit"]}, "a utility that declares phases"),
        ("b-commit", {"role": "orchestrator"}, "a second orchestrator"),
    ):
        if not contract_errors(name, change):
            errors.append(f"contract regression: {why} must fail")
    for name, change, why in (
        (
            "b-flow",
            {"intent": "Changes that route to b-implement, b-frontend, or b-refactor"},
            "an entry line that omits one",
        ),
        (
            "b-flow",
            {"intent": "Changes that route to b-implement, b-frontend, b-refactor, b-test, or b-qa"},
            "an entry line that adds one",
        ),
        ("b-flow", {"entry": False, "triggers": ["run"]}, "an orchestrator that is not the entry"),
        ("b-plan", {"entry": True}, "a second routing entry"),
    ):
        candidate = json.loads(json.dumps(skills))
        next(skill for skill in candidate if skill["name"] == name)["routing"].update(change)
        if not validate_contracts(candidate):
            errors.append(f"routing regression: {why} must fail")
    candidate = json.loads(json.dumps(skills))
    next(skill for skill in candidate if skill["name"] == "b-flow")["routing"]["explicit_request"] = True
    if not any("not both" in error for error in validate_skills(candidate, agents)):
        errors.append("routing regression: an explicit-request routing entry must fail")
    if f"-> `b-flow`{ENTRY_ROUTING_SUFFIX}." not in render_routing(skills):
        errors.append("routing regression: the kernel must route changes through the b-flow entry line")
    flow = next(skill for skill in skills if skill["name"] == "b-flow")
    for runtime in RUNTIMES:
        rendered = render_skill_file(flow, runtime)
        if PHASE_CONTRACTS_PLACEHOLDER in rendered or any(f"| {phase} |" not in rendered for phase in packet_phases()):
            errors.append(f"contract regression: the {runtime} b-flow skill must carry the phase table")
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
            gate = primary_gate(skill, "claude")
            required = (
                f"`{skill['name']}` runs the {gate['label']} gate first, from the main session as the Steps direct;"
                if gate
                else f"`{skill['name']}` runs only in the `{agent_name}` subagent.",
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
    errors.extend(validate_worker_regressions(agents, policy, workers))
    invalid_capabilities = json.loads(json.dumps(capabilities))
    invalid_capabilities["capabilities"][0].pop("status_signal", None)
    if not validate_capabilities(invalid_capabilities, policy):
        errors.append("capability regression: missing status signal must fail")
    invalid_agent_tools = json.loads(json.dumps(agents))
    invalid_agent_tools["b-researcher"]["conditional_tools"].append("mcp__playwright__browser_click")
    if not validate_agent_tools(invalid_agent_tools, policy):
        errors.append("agent regression: mutating conditional tool must fail")
    errors.extend(validate_snapshot_cli())
    errors.extend(validate_artifacts_schema())
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
    errors.extend(validate_pi_regressions(skills, agents, policy))
    return errors


def validate_pi_regressions(
    skills: list[dict[str, Any]], agents: dict[str, dict[str, Any]], policy: dict[str, Any]
) -> list[str]:
    errors: list[str] = []
    for bad in ("<!-- runtime: cluade --> text", "text <!-- runtime: pi -->"):
        try:
            apply_markers(bad, "pi")
        except ValueError:
            continue
        errors.append(f"runtime regression: malformed marker {bad!r} must fail")
    if apply_markers("a\n<!-- runtime: pi --> b\n<!-- runtime: claude --> c\nd", "claude") != "a\nc\nd":
        errors.append("runtime regression: Claude must keep only shared and claude-marked lines")
    if apply_markers("a\n<!-- runtime: pi --> b\n<!-- runtime: claude --> c\nd", "pi") != "a\nb\nd":
        errors.append("runtime regression: Pi must keep only shared and pi-marked lines")
    for text in ("no match here", "Claude Code Workflow Kernel Claude Code Workflow Kernel"):
        try:
            apply_kernel_overrides(text, "pi")
        except ValueError:
            continue
        errors.append(f"runtime regression: a drifted kernel override must fail on {text!r}")
    if not forbidden_hits("see ~/.claude/b-agentic", "pi"):
        errors.append("runtime regression: a leaked Claude path must be detected in Pi output")
    if not validate_pi_agent_tools("b-x", ["read", "edit"]) or not validate_pi_agent_tools("b-x", ["subagent"]):
        errors.append("runtime regression: a Pi agent with edit or subagent tools must fail")
    if not validate_pi_agent_tools("b-x", ["mcp:notion/notion-search"]):
        errors.append("runtime regression: a Pi agent with a Notion tool must fail")
    for skill in skills:
        claude = render_skill_file(skill)
        if "<!-- runtime:" in claude:
            errors.append(f"runtime regression: {skill['name']} Claude render has an unresolved marker")
    review = next(skill for skill in skills if skill["name"] == "b-review")
    if "Codex" not in render_skill_file(review) or "Codex" in render_skill_file(review, "pi"):
        errors.append("runtime regression: Codex steps must stay on Claude and be absent on Pi")
    broken = json.loads(json.dumps(RUNTIMES["pi"]))
    broken["packages"] = ["npm:pi-subagents"]
    if not any("exact npm" in error for error in validate_pi_runtime(broken)):
        errors.append("runtime regression: an unpinned Pi package must fail")
    errors.extend(pi_output_errors(skills, agents, policy))
    return errors


def validate_runtimes() -> list[str]:
    errors: list[str] = []
    for name, config in RUNTIMES.items():
        label = f"{RUNTIMES_PATH.relative_to(ROOT)}: runtimes.{name}"
        for key in (
            "config_dir",
            "state_dir",
            "hook_dir",
            "mcp_tool_format",
            "delegation_unavailable",
            "profile_check",
        ):
            ensure_string(config.get(key), f"{label}.{key}", errors)
        for key in ("agent_models", "editing_tools"):
            if not isinstance(config.get(key), list) or not all(isinstance(item, str) and item for item in config[key]):
                errors.append(f"{label}.{key}: expected a string array")
        template = config.get("mcp_tool_format")
        if isinstance(template, str) and not ("{server}" in template and "{tool}" in template):
            errors.append(f"{label}.mcp_tool_format: must contain {{server}} and {{tool}}")
    claude = RUNTIMES["claude"]
    if claude.get("mcp_tool_format") != "mcp__{server}__{tool}":
        errors.append("runtimes.claude: MCP format must be mcp__{server}__{tool}")
    errors.extend(validate_pi_runtime(RUNTIMES.get("pi")))
    return errors


def validate_pi_runtime(pi: object) -> list[str]:
    label = f"{RUNTIMES_PATH.relative_to(ROOT)}: runtimes.pi"
    if not isinstance(pi, dict):
        return [f"{label}: missing"]
    errors: list[str] = []
    for key in ("read_only_tools", "excluded_agent_tools", "forbidden_tokens", "packages", "allowed_tools"):
        non_empty_string_list(pi.get(key), f"{label}.{key}", errors)
    exposure = pi.get("mcp_exposure")
    if (
        not isinstance(exposure, dict)
        or exposure.get("default") not in {"direct", "deferred"}
        or not isinstance(exposure.get("direct"), list)
    ):
        errors.append(f"{label}.mcp_exposure: expected {{default: direct|deferred, direct: [server names]}}")
    for key in ("glossary", "kernel_overrides"):
        entries = pi.get(key)
        if not isinstance(entries, list) or not entries:
            errors.append(f"{label}.{key}: expected a non-empty array of {{from, to}} objects")
            continue
        for index, entry in enumerate(entries, start=1):
            if (
                not isinstance(entry, dict)
                or set(entry) != {"from", "to"}
                or not isinstance(entry["from"], str)
                or not entry["from"]
                or not isinstance(entry["to"], str)
            ):
                errors.append(f"{label}.{key}[{index}]: expected {{from: non-empty string, to: string}}")
    for package in pi.get("packages", []) if isinstance(pi.get("packages"), list) else []:
        if not isinstance(package, str) or not re.fullmatch(
            r"npm:(@[a-z0-9._-]+/)?[a-z0-9._-]+@\d+\.\d+\.\d+", package
        ):
            errors.append(f"{label}.packages: {package!r} must be an exact npm:name@x.y.z pin")
    excluded = pi.get("excluded_agent_tools", [])
    editing = pi.get("editing_tools", [])
    if isinstance(excluded, list) and isinstance(editing, list):
        missing = [tool for tool in (*editing, "subagent") if tool not in excluded]
        if missing:
            errors.append(f"{label}.excluded_agent_tools: must include {missing}")
    if pi.get("mcp_tool_format") != "mcp__{server}__{tool}":
        errors.append(f"{label}: MCP format must be mcp__{{server}}__{{tool}} (confirm with spike S7 before changing)")
    return errors


def sync_outputs(check: bool) -> int:
    skills = load_skills()
    agents = load_agents()
    workers = load_workers()
    policy = load_policy()
    capabilities = load_capabilities()
    errors = [
        *validate_skills(skills, agents),
        *validate_workers(workers, agents),
        *validate_contracts(skills),
        *validate_policy(policy),
        *validate_agent_tools(agents, policy),
        *validate_optional_components(skills, policy),
        *validate_capabilities(capabilities, policy),
        *validate_snapshot_cli(),
        *validate_artifacts_schema(),
        *validate_runtimes(),
    ]
    if not errors:
        errors.extend(pi_output_errors(skills, agents, policy))
    if errors:
        print("\n".join(errors), file=sys.stderr)
        return 1
    outputs = render_outputs(skills, agents, policy, workers)
    stale = [path for path, content in outputs.items() if not path.exists() or path.read_text() != content]
    if check and stale:
        print("\n".join(f"generated output out of date: {path.relative_to(ROOT)}" for path in stale), file=sys.stderr)
        return 1
    if not check:
        for path in stale:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(outputs[path])
        print("Generated Claude Code and Pi delivery assets refreshed.")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description="Render Claude Code assets from canonical b-agentic sources.")
    parser.add_argument("--check", action="store_true", help="fail when generated outputs are stale")
    parser.add_argument("--self-test", action="store_true", help="verify invalid canonical contracts fail validation")
    args = parser.parse_args()
    if args.self_test:
        errors = validate_regressions(load_skills(), load_agents(), load_capabilities(), load_policy(), load_workers())
        if errors:
            print("\n".join(errors), file=sys.stderr)
            return 1
        print("Skill, capability, and MCP policy regression checks passed.")
    return sync_outputs(args.check)


if __name__ == "__main__":
    raise SystemExit(main())
